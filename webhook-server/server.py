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
            if os.environ.get('FLASK_ENV') == 'development':
                logger.warning("No signature provided (development mode)")
                return f(*args, **kwargs)
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
    """Health check endpoint"""
    return jsonify({
        'status': 'healthy',
        'timestamp': datetime.now().isoformat(),
        'projects': list(set(c.get('name', 'unknown') for c in PROJECT_CONFIGS.values()))
    })


@app.route('/projects', methods=['GET'])
def list_projects():
    """List all configured projects"""
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

            env = {
                **os.environ,
                'PROJECT_NAME': project_name,
                'PROJECT_PATH': os.path.join(HOSTING_DIR, config.get('path', '')),
                'COMPOSE_FILE': config.get('compose_file', ''),
                'COMPOSE_DIR': config.get('compose_dir', ''),
                'REPOS': ','.join(config.get('repos', [])),
                'BRANCH': branch
            }

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
            else:
                error_msg = stderr.decode()[-1000:]
                logger.error(f"Deployment failed for {project_name}: {error_msg}")

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
def reload_config():
    """Reload project configurations"""
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

    if os.environ.get('FLASK_ENV') == 'development':
        app.run(host='0.0.0.0', port=port, debug=True)
    else:
        try:
            from waitress import serve
            logger.info(f"Starting production server on port {port}")
            serve(app, host='0.0.0.0', port=port)
        except ImportError:
            logger.warning("Waitress not installed, using Flask dev server")
            app.run(host='0.0.0.0', port=port)
