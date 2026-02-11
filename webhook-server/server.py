#!/usr/bin/env python3
"""
Central Deployment Webhook Server
Handles GitHub webhooks for all projects in ~/Hosting/
"""

import os
import hmac
import hashlib
import subprocess
import logging
import json
import threading
import time
import re
import yaml
from datetime import datetime
from flask import Flask, request, jsonify
from functools import wraps

app = Flask(__name__)

# Configuration
WEBHOOK_SECRET = os.environ.get('WEBHOOK_SECRET', 'change-me-in-production')
HOSTING_DIR = os.environ.get('HOSTING_DIR', '/home/bloster/Hosting')
DEPLOY_SCRIPT = os.path.join(os.path.dirname(__file__), 'deploy.sh')
CONFIG_DIR = os.path.join(os.path.dirname(__file__), 'projects')
LOG_FILE = '/var/log/infra/webhook.log'

# Ensure log directory exists
os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

# Load project configurations
def load_project_configs():
    """Load all project configurations from YAML files"""
    configs = {}
    if os.path.exists(CONFIG_DIR):
        for filename in os.listdir(CONFIG_DIR):
            if filename.endswith('.yml') or filename.endswith('.yaml'):
                filepath = os.path.join(CONFIG_DIR, filename)
                with open(filepath, 'r') as f:
                    config = yaml.safe_load(f)
                    if config and 'repos' in config:
                        for repo in config['repos']:
                            configs[repo] = config
    return configs

PROJECT_CONFIGS = load_project_configs()


def verify_signature(f):
    """Decorator to verify GitHub webhook signature"""
    @wraps(f)
    def decorated_function(*args, **kwargs):
        signature = request.headers.get('X-Hub-Signature-256')

        if not signature:
            logger.warning("No signature provided")
            return jsonify({'error': 'No signature'}), 401

        expected = 'sha256=' + hmac.new(
            WEBHOOK_SECRET.encode(),
            request.data,
            hashlib.sha256
        ).hexdigest()

        if not hmac.compare_digest(signature, expected):
            logger.warning("Invalid signature")
            return jsonify({'error': 'Invalid signature'}), 401

        return f(*args, **kwargs)
    return decorated_function


@app.route('/health', methods=['GET'])
def health():
    """Health check endpoint (minimal info)"""
    return jsonify({
        'status': 'healthy',
        'timestamp': datetime.now().isoformat()
    })


@app.route('/projects', methods=['GET'])
@verify_signature
def list_projects():
    """List all configured projects (requires webhook signature)"""
    projects = {}
    for repo, config in PROJECT_CONFIGS.items():
        name = config.get('name', 'unknown')
        if name not in projects:
            projects[name] = {
                'name': name,
                'repos': config.get('repos', []),
                'path': config.get('path', ''),
                'branch': config.get('branch', 'main')
            }
    return jsonify({'projects': list(projects.values())})


@app.route('/status', methods=['GET'])
def status():
    """Check current deployment status"""
    lock_file = '/tmp/infra_deploy.lock'

    if os.path.isdir(lock_file):
        try:
            with open(os.path.join(lock_file, 'pid'), 'r') as f:
                pid = f.read().strip()
            with open(os.path.join(lock_file, 'project'), 'r') as f:
                project = f.read().strip()
            with open(os.path.join(lock_file, 'started'), 'r') as f:
                started = f.read().strip()

            # Check if process is still running
            try:
                os.kill(int(pid), 0)
                return jsonify({
                    'deploying': True,
                    'project': project,
                    'pid': pid,
                    'started': started
                })
            except (OSError, ValueError):
                return jsonify({'deploying': False, 'note': 'stale lock detected'})
        except FileNotFoundError:
            return jsonify({'deploying': False})

    return jsonify({'deploying': False})


@app.route('/deploy', methods=['POST'])
@verify_signature
def deploy():
    """Main deployment webhook endpoint"""
    payload = request.json or {}

    # Get branch from ref
    ref = payload.get('ref', '')
    branch = ref.replace('refs/heads/', '') if ref.startswith('refs/heads/') else ''

    repo_name = payload.get('repository', {}).get('name', 'unknown')
    pusher = payload.get('pusher', {}).get('name', 'unknown')

    logger.info(f"Webhook received: {repo_name} on {branch} by {pusher}")

    # Find project config for this repo
    if repo_name not in PROJECT_CONFIGS:
        logger.info(f"Repository {repo_name} not configured for deployment")
        return jsonify({'message': f'Repository {repo_name} not configured'}), 200

    config = PROJECT_CONFIGS[repo_name]
    project_name = config.get('name', repo_name)
    allowed_branches = config.get('branch', ['main', 'master', 'prod'])
    if isinstance(allowed_branches, str):
        allowed_branches = [allowed_branches]

    # Check branch
    if branch not in allowed_branches:
        logger.info(f"Ignoring push to {branch} (allowed: {allowed_branches})")
        return jsonify({'message': f'Branch {branch} not configured for deployment'}), 200

    # Check if already deploying
    status_resp = status()
    status_data = status_resp.get_json()

    if status_data.get('deploying'):
        logger.warning("Deployment already in progress")
        return jsonify({
            'status': 'busy',
            'message': 'Another deployment is in progress',
            'details': status_data
        }), 503

    # Run deployment asynchronously
    def run_deployment():
        start_time = time.time()
        try:
            logger.info(f"Starting deployment for {project_name}")

            # Construire les variables d'environnement pour deploy.sh
            # IMPORTANT: On utilise DEPLOY_COMPOSE_FILE au lieu de COMPOSE_FILE
            # car docker compose utilise COMPOSE_FILE nativement
            env = {
                **os.environ,
                'PROJECT_NAME': project_name,
                'PROJECT_PATH': os.path.join(HOSTING_DIR, config.get('path', '')),
                'DEPLOY_COMPOSE_FILE': config.get('compose_file', ''),
                'COMPOSE_DIR': config.get('compose_dir', ''),
                'REPOS': ','.join(config.get('repos', [])),
                'BRANCH': branch
            }
            # Supprimer COMPOSE_FILE de l'env pour ne pas interférer avec docker compose
            env.pop('COMPOSE_FILE', None)

            process = subprocess.Popen(
                ['/bin/bash', DEPLOY_SCRIPT],
                cwd=HOSTING_DIR,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=env
            )

            stdout, stderr = process.communicate(timeout=600)
            duration = time.time() - start_time

            if process.returncode == 0:
                logger.info(f"Deployment completed for {project_name} in {duration:.1f}s")
                if stdout:
                    logger.debug(f"[{project_name}] stdout: {stdout.decode()[-500:]}")
            else:
                out_msg = stdout.decode()[-500:] if stdout else ""
                err_msg = stderr.decode()[-1000:] if stderr else ""
                logger.error(f"Deployment failed for {project_name} (exit {process.returncode}):\n"
                             f"STDOUT: {out_msg}\nSTDERR: {err_msg}")

        except subprocess.TimeoutExpired:
            process.kill()
            logger.error(f"Deployment timed out for {project_name}")
        except Exception as e:
            logger.error(f"Deployment error for {project_name}: {str(e)}")

    thread = threading.Thread(target=run_deployment, daemon=True)
    thread.start()

    return jsonify({
        'status': 'accepted',
        'message': 'Deployment started',
        'project': project_name,
        'repo': repo_name,
        'branch': branch,
        'triggered_by': pusher
    }), 202


@app.route('/reload-config', methods=['POST'])
@verify_signature
def reload_config():
    """Reload project configurations (requires webhook signature)"""
    global PROJECT_CONFIGS
    PROJECT_CONFIGS = load_project_configs()
    return jsonify({
        'message': 'Configuration reloaded',
        'projects': list(set(c.get('name', 'unknown') for c in PROJECT_CONFIGS.values()))
    })


# ============================================
# System Stats API (for admin dashboard)
# ============================================

@app.route('/api/system', methods=['GET'])
def api_system():
    """Get Raspberry Pi system stats"""
    try:
        # CPU usage
        cpu_percent = 0.0
        try:
            with open('/proc/stat', 'r') as f:
                lines = f.readlines()
            cpu_line = lines[0].split()
            user, nice, system, idle, iowait, irq, softirq = map(int, cpu_line[1:8])
            total = user + nice + system + idle + iowait + irq + softirq
            idle_time = idle + iowait
            # Simple approximation - use load average instead for accuracy
            with open('/proc/loadavg', 'r') as f:
                load = float(f.read().split()[0])
            # Raspberry Pi 4 has 4 cores, so 100% per core
            cpu_percent = min(load * 25, 100)  # Approximate percentage
        except:
            pass

        # Memory
        mem_total = 0
        mem_used = 0
        mem_available = 0
        try:
            with open('/proc/meminfo', 'r') as f:
                meminfo = {}
                for line in f:
                    parts = line.split()
                    meminfo[parts[0].rstrip(':')] = int(parts[1]) * 1024  # Convert to bytes
            mem_total = meminfo.get('MemTotal', 0)
            mem_available = meminfo.get('MemAvailable', 0)
            mem_used = mem_total - mem_available
        except:
            pass

        # Disk
        disk_total = 0
        disk_used = 0
        try:
            result = subprocess.run(['df', '-B1', '/'], capture_output=True, text=True)
            if result.returncode == 0:
                lines = result.stdout.strip().split('\n')
                if len(lines) > 1:
                    parts = lines[1].split()
                    disk_total = int(parts[1])
                    disk_used = int(parts[2])
        except:
            pass

        # Temperature
        temperature = 0.0
        try:
            with open('/sys/class/thermal/thermal_zone0/temp', 'r') as f:
                temperature = int(f.read().strip()) / 1000.0
        except:
            pass

        # Uptime
        uptime_str = ""
        try:
            with open('/proc/uptime', 'r') as f:
                uptime_seconds = float(f.read().split()[0])
            days = int(uptime_seconds // 86400)
            hours = int((uptime_seconds % 86400) // 3600)
            minutes = int((uptime_seconds % 3600) // 60)
            if days > 0:
                uptime_str = f"{days}j {hours}h {minutes}m"
            elif hours > 0:
                uptime_str = f"{hours}h {minutes}m"
            else:
                uptime_str = f"{minutes}m"
        except:
            uptime_str = "unknown"

        return jsonify({
            'cpu': {
                'percent': cpu_percent
            },
            'memory': {
                'total': mem_total,
                'used': mem_used,
                'available': mem_available
            },
            'disk': {
                'total': disk_total,
                'used': disk_used
            },
            'temperature': temperature,
            'uptime': uptime_str
        })

    except Exception as e:
        logger.error(f"Failed to get system stats: {e}")
        return jsonify({'error': str(e)}), 500


@app.route('/api/docker', methods=['GET'])
def api_docker():
    """Get Docker container status"""
    try:
        result = subprocess.run(
            ['docker', 'ps', '-a', '--format', '{{.Names}}\t{{.State}}\t{{.Status}}'],
            capture_output=True,
            text=True
        )

        containers = []
        if result.returncode == 0:
            for line in result.stdout.strip().split('\n'):
                if line:
                    parts = line.split('\t')
                    if len(parts) >= 3:
                        containers.append({
                            'name': parts[0],
                            'state': parts[1],
                            'status': parts[2]
                        })

        # Sort: running first, then alphabetically
        containers.sort(key=lambda c: (0 if c['state'] == 'running' else 1, c['name']))

        return jsonify({
            'containers': containers,
            'total': len(containers),
            'running': len([c for c in containers if c['state'] == 'running'])
        })

    except Exception as e:
        logger.error(f"Failed to get docker stats: {e}")
        return jsonify({'error': str(e)}), 500


@app.route('/api/ssl', methods=['GET'])
def api_ssl():
    """Get SSL certificate status for all domains"""
    try:
        certs = []
        letsencrypt_dir = '/home/bloster/Hosting/Infra/certbot/conf/live'

        if os.path.exists(letsencrypt_dir):
            for domain in os.listdir(letsencrypt_dir):
                if domain.startswith('.') or domain == 'README':
                    continue

                cert_path = os.path.join(letsencrypt_dir, domain, 'fullchain.pem')
                if not os.path.exists(cert_path):
                    continue

                # Get certificate expiry date using openssl
                try:
                    result = subprocess.run(
                        ['openssl', 'x509', '-enddate', '-noout', '-in', cert_path],
                        capture_output=True,
                        text=True
                    )
                    if result.returncode == 0:
                        # Parse: notAfter=Mar 15 12:00:00 2026 GMT
                        line = result.stdout.strip()
                        date_str = line.replace('notAfter=', '')
                        # Parse the date
                        from datetime import datetime
                        expiry = datetime.strptime(date_str, '%b %d %H:%M:%S %Y %Z')
                        days_left = (expiry - datetime.now()).days

                        # Get domains covered by cert
                        result_san = subprocess.run(
                            ['openssl', 'x509', '-in', cert_path, '-noout', '-text'],
                            capture_output=True,
                            text=True
                        )
                        domains_covered = [domain]
                        if result_san.returncode == 0:
                            # Extract SAN domains
                            for line in result_san.stdout.split('\n'):
                                if 'DNS:' in line:
                                    sans = re.findall(r'DNS:([^,\s]+)', line)
                                    domains_covered = sans if sans else [domain]
                                    break

                        certs.append({
                            'name': domain,
                            'domains': domains_covered,
                            'expiry': expiry.isoformat(),
                            'days_left': days_left,
                            'status': 'valid' if days_left > 30 else 'expiring' if days_left > 0 else 'expired'
                        })
                except Exception as e:
                    logger.warning(f"Failed to parse cert for {domain}: {e}")
                    certs.append({
                        'name': domain,
                        'domains': [domain],
                        'expiry': None,
                        'days_left': None,
                        'status': 'error'
                    })

        # Sort by days left (most urgent first)
        certs.sort(key=lambda c: c['days_left'] if c['days_left'] is not None else 999)

        return jsonify({
            'certificates': certs,
            'total': len(certs)
        })

    except Exception as e:
        logger.error(f"Failed to get SSL stats: {e}")
        return jsonify({'error': str(e)}), 500


if __name__ == '__main__':
    logger.info(f"Starting webhook server")
    logger.info(f"Hosting directory: {HOSTING_DIR}")
    logger.info(f"Projects configured: {list(set(c.get('name', 'unknown') for c in PROJECT_CONFIGS.values()))}")

    port = int(os.environ.get('PORT', 9000))

    try:
        from waitress import serve
        logger.info(f"Starting production server on port {port}")
        serve(app, host='0.0.0.0', port=port)
    except ImportError:
        logger.warning("Waitress not installed, using Flask dev server (debug disabled)")
        app.run(host='0.0.0.0', port=port, debug=False)
