#!/usr/bin/env python3
"""
Central Deployment Webhook Server + Admin Dashboard
Handles GitHub webhooks for all projects in ~/Hosting/
Serves admin dashboard with system monitoring APIs
"""

import os
import hmac
import hashlib
import subprocess
import logging
import threading
import time
import json
import yaml
import urllib.request
from datetime import datetime
from flask import Flask, request, jsonify, send_from_directory
from functools import wraps

ADMIN_DIR = os.path.join(os.path.dirname(__file__), 'admin')
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

# Network rate tracking
_prev_net = {'time': 0, 'rx': 0, 'tx': 0}

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


# ============================================
# ADMIN DASHBOARD
# ============================================

@app.route('/')
def admin_index():
    """Serve admin dashboard"""
    return send_from_directory(ADMIN_DIR, 'index.html')


@app.route('/health', methods=['GET'])
def health():
    """Health check endpoint"""
    return jsonify({
        'status': 'healthy',
        'timestamp': datetime.now().isoformat()
    })


@app.route('/api/system', methods=['GET'])
def api_system():
    """ProDesk system stats from /proc/"""
    global _prev_net
    data = {}

    try:
        with open('/proc/loadavg') as f:
            load1 = float(f.read().split()[0])
        cores = os.cpu_count() or 1
        data['cpu'] = {'percent': round(min(load1 / cores * 100, 100), 1)}
    except Exception:
        data['cpu'] = {'percent': 0}

    try:
        with open('/proc/meminfo') as f:
            info = {}
            for line in f:
                parts = line.split()
                if len(parts) >= 2:
                    info[parts[0].rstrip(':')] = int(parts[1]) * 1024
            total = info.get('MemTotal', 0)
            available = info.get('MemAvailable', 0)
            data['memory'] = {
                'total': total,
                'used': total - available,
                'available': available
            }
    except Exception:
        data['memory'] = {'total': 0, 'used': 0, 'available': 0}

    try:
        result = subprocess.run(['df', '-B1', '/'], capture_output=True, text=True, timeout=5)
        parts = result.stdout.strip().split('\n')[-1].split()
        data['disk'] = {'total': int(parts[1]), 'used': int(parts[2])}
    except Exception:
        data['disk'] = {'total': 0, 'used': 0}

    try:
        with open('/sys/class/thermal/thermal_zone0/temp') as f:
            data['temperature'] = round(int(f.read().strip()) / 1000, 1)
    except Exception:
        data['temperature'] = None

    try:
        with open('/proc/net/dev') as f:
            rx_total = tx_total = 0
            for line in f:
                if ':' in line and 'lo' not in line:
                    parts = line.split(':')[1].split()
                    rx_total += int(parts[0])
                    tx_total += int(parts[8])
        now = time.time()
        dt = now - _prev_net['time'] if _prev_net['time'] else 0
        rx_rate = (rx_total - _prev_net['rx']) / dt if dt > 0 else 0
        tx_rate = (tx_total - _prev_net['tx']) / dt if dt > 0 else 0
        _prev_net = {'time': now, 'rx': rx_total, 'tx': tx_total}
        data['network'] = {
            'rx_total': rx_total, 'tx_total': tx_total,
            'rx_rate': round(rx_rate), 'tx_rate': round(tx_rate)
        }
    except Exception:
        data['network'] = {'rx_total': 0, 'tx_total': 0, 'rx_rate': 0, 'tx_rate': 0}

    try:
        with open('/proc/uptime') as f:
            secs = int(float(f.read().split()[0]))
        days, rem = divmod(secs, 86400)
        hours, rem = divmod(rem, 3600)
        mins = rem // 60
        parts = []
        if days:
            parts.append(f"{days}j")
        if hours:
            parts.append(f"{hours}h")
        parts.append(f"{mins}m")
        data['uptime'] = ' '.join(parts)
    except Exception:
        data['uptime'] = '?'

    return jsonify(data)


@app.route('/api/docker', methods=['GET'])
def api_docker():
    """Docker container list and status"""
    try:
        result = subprocess.run(
            ['docker', 'ps', '-a', '--format', '{{json .}}'],
            capture_output=True, text=True, timeout=10
        )
        containers = []
        for line in result.stdout.strip().split('\n'):
            if not line:
                continue
            c = json.loads(line)
            containers.append({
                'name': c.get('Names', ''),
                'state': c.get('State', ''),
                'status': c.get('Status', ''),
                'image': c.get('Image', '').split(':')[0].split('/')[-1]
            })

        # Sort: running first, then alphabetically
        containers.sort(key=lambda x: (0 if x['state'] == 'running' else 1, x['name']))
        running = sum(1 for c in containers if c['state'] == 'running')

        return jsonify({
            'containers': containers,
            'total': len(containers),
            'running': running
        })
    except Exception as e:
        logger.error(f"Docker API error: {e}")
        return jsonify({'containers': [], 'total': 0, 'running': 0, 'error': str(e)})


@app.route('/api/pi4', methods=['GET'])
def api_pi4():
    """Raspberry Pi 4 stats via LAN"""
    try:
        req = urllib.request.Request('http://192.168.1.62:8080/api/host-stats', method='GET')
        with urllib.request.urlopen(req, timeout=5) as resp:
            return jsonify(json.loads(resp.read()))
    except Exception as e:
        logger.error(f"Pi 4 API error: {e}")
        return jsonify({'error': str(e)}), 502


# Pi-hole session cache (avoid re-auth every request → 429 rate limit)
_pihole_sid = {'sid': None, 'expires': 0}


def _pihole_get_sid():
    """Get or refresh Pi-hole session token."""
    global _pihole_sid
    if _pihole_sid['sid'] and time.time() < _pihole_sid['expires']:
        return _pihole_sid['sid']

    pw = os.environ.get('PIHOLE_PASSWORD', '')
    auth_data = json.dumps({'password': pw}).encode()
    auth_req = urllib.request.Request(
        'http://pihole/api/auth', data=auth_data, method='POST',
        headers={'Content-Type': 'application/json'}
    )
    with urllib.request.urlopen(auth_req, timeout=5) as resp:
        auth = json.loads(resp.read())

    sid = auth.get('session', {}).get('sid')
    validity = auth.get('session', {}).get('validity', 300)
    if not sid:
        raise ValueError('Pi-hole auth failed')

    _pihole_sid = {'sid': sid, 'expires': time.time() + validity - 30}
    return sid


@app.route('/api/pihole', methods=['GET'])
def api_pihole():
    """Pi-hole stats via internal Docker network (v6 auth)"""
    try:
        sid = _pihole_get_sid()

        stats_req = urllib.request.Request('http://pihole/api/stats/summary', method='GET')
        stats_req.add_header('sid', sid)
        with urllib.request.urlopen(stats_req, timeout=5) as resp:
            data = json.loads(resp.read())

        return jsonify({
            'queries': data.get('queries', {}).get('total', 0),
            'blocked': data.get('queries', {}).get('blocked', 0),
            'percent': data.get('queries', {}).get('percent_blocked', 0),
            'status': 'enabled'
        })
    except Exception as e:
        _pihole_sid['sid'] = None  # Force re-auth on next call
        logger.error(f"Pi-hole API error: {e}")
        return jsonify({'queries': 0, 'blocked': 0, 'percent': 0, 'status': 'error'})


# ============================================
# WEBHOOK ENDPOINTS
# ============================================

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

            # IMPORTANT: DEPLOY_COMPOSE_FILE instead of COMPOSE_FILE
            # because docker compose uses COMPOSE_FILE natively
            env = {
                **os.environ,
                'PROJECT_NAME': project_name,
                'PROJECT_PATH': os.path.join(HOSTING_DIR, config.get('path', '')),
                'DEPLOY_COMPOSE_FILE': config.get('compose_file', ''),
                'COMPOSE_DIR': config.get('compose_dir', ''),
                'REPOS': ','.join(config.get('repos', [])),
                'BRANCH': branch,
                'SERVICES': ','.join(config.get('services', [])),
            }
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
