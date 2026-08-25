#!/usr/bin/env python3
"""
Clone (or update) all repositories in a GitLab group, including subgroups.

Requirements:
    pip install python-gitlab

Usage examples:
    # HTTPS clone using a personal access token
    python clone_gitlab_group.py --token glpat-xxxxxxxx --group my-org/my-group

    # Self-hosted GitLab instance
    python clone_gitlab_group.py --url https://gitlab.mycompany.com \
        --token glpat-xxxxxxxx --group my-group --dest ./repos

    # Clone via SSH instead of HTTPS (requires SSH keys already set up)
    python clone_gitlab_group.py --token glpat-xxxxxxxx --group my-group --ssh

Notes:
    - "--group" accepts either the numeric group ID or the URL-friendly
      path (e.g. "my-org/my-subgroup").
    - By default subgroup projects are included; use --no-subgroups to
      restrict to the top-level group only.
    - You can also set the token via the GITLAB_TOKEN environment
      variable instead of passing --token on the command line.
"""

import argparse
import os
import subprocess
import sys

try:
    import gitlab
except ImportError:
    sys.exit("Missing dependency. Install it with: pip install python-gitlab")


def get_all_projects(gl, group_id, include_subgroups=True):
    """Fetch all projects belonging to a group (paginated, so use all=True)."""
    group = gl.groups.get(group_id)
    return group.projects.list(all=True, include_subgroups=include_subgroups)


def build_authed_https_url(http_url, token):
    """Embed the access token into an HTTPS clone URL so git doesn't prompt for creds."""
    if "://" not in http_url:
        return http_url
    scheme, rest = http_url.split("://", 1)
    return f"{scheme}://oauth2:{token}@{rest}"


def clone_or_pull(project, dest_dir, token, use_ssh=False):
    """Clone the project if it doesn't exist locally, otherwise pull latest changes."""
    local_path = os.path.join(dest_dir, project.path_with_namespace)

    if use_ssh:
        repo_url = project.ssh_url_to_repo
    else:
        repo_url = build_authed_https_url(project.http_url_to_repo, token)

    if os.path.exists(local_path):
        print(f"[update] {project.path_with_namespace}")
        subprocess.run(["git", "-C", local_path, "pull"], check=True)
    else:
        print(f"[clone]  {project.path_with_namespace}")
        os.makedirs(os.path.dirname(local_path) or ".", exist_ok=True)
        subprocess.run(["git", "clone", repo_url, local_path], check=True)


def main():
    parser = argparse.ArgumentParser(description="Clone/update all repos in a GitLab group")
    parser.add_argument("--url", default="https://gitlab.com", help="GitLab instance URL")
    parser.add_argument(
        "--token",
        default=os.environ.get("GITLAB_TOKEN"),
        help="Personal access token (or set GITLAB_TOKEN env var)",
    )
    parser.add_argument("--group", required=True, help="Group path or numeric ID")
    parser.add_argument("--dest", default="./repos", help="Destination directory")
    parser.add_argument("--ssh", action="store_true", help="Use SSH URLs instead of HTTPS")
    parser.add_argument(
        "--no-subgroups", action="store_true", help="Exclude projects from subgroups"
    )
    args = parser.parse_args()

    if not args.token:
        sys.exit("A token is required: pass --token or set GITLAB_TOKEN.")

    gl = gitlab.Gitlab(args.url, private_token=args.token)
    gl.auth()  # verifies the token is valid

    os.makedirs(args.dest, exist_ok=True)

    projects = get_all_projects(gl, args.group, include_subgroups=not args.no_subgroups)
    print(f"Found {len(projects)} project(s) in group '{args.group}'\n")

    failures = []
    for project in projects:
        try:
            clone_or_pull(project, args.dest, args.token, use_ssh=args.ssh)
        except subprocess.CalledProcessError as e:
            print(f"  !! failed: {project.path_with_namespace} ({e})")
            failures.append(project.path_with_namespace)

    print(f"\nDone. {len(projects) - len(failures)} succeeded, {len(failures)} failed.")
    if failures:
        print("Failed:", ", ".join(failures))


if __name__ == "__main__":
    main()
