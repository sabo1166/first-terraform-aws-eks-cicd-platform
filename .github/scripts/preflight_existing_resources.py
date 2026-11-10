#!/usr/bin/env python3
"""Read-only preflight: fail if a resource the plan would CREATE already exists in AWS.

Why: a create-only plan applied against an account that already holds some of these
resources (made by hand, or by an earlier run whose Terraform state was lost) either fails
partway with "AlreadyExists" or, for resources with generated IDs (VPC, NAT gateway, Elastic
IP), silently creates duplicates, some of them billable.

Safety:
  * Only AWS READ calls (get/describe/list). It never creates, changes or imports anything.
  * It never reads or writes Terraform state. It reads the saved-plan JSON only.
  * On a conflict it exits non-zero and prints the resources. An administrator then
    decides (remove the manual resource, or `terraform import` it as an administrator).
  * Fail closed: anything it cannot verify (access denied, unexpected error) also fails.

Usage: preflight_existing_resources.py <plan.json>
Test hook: PREFLIGHT_AWS_CMD overrides the aws command (e.g. "python fake_aws.py").
"""
import json
import os
import shlex
import subprocess
import sys

AWS = shlex.split(os.environ.get("PREFLIGHT_AWS_CMD", "aws"))

# Per-type "not found" error markers for lookups that error when the resource is absent.
NOT_FOUND = ("NoSuchEntity", "ResourceNotFoundException", "RepositoryNotFoundException")


def aws(*args):
    proc = subprocess.run([*AWS, *args, "--output", "json"], capture_output=True, text=True)
    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()


def exists_by_error(*args):
    """Lookup that returns data when present and a *NotFound error when absent."""
    rc, _out, err = aws(*args)
    if rc == 0:
        return True
    if any(marker in err for marker in NOT_FOUND):
        return False
    raise RuntimeError(err.splitlines()[-1] if err else "unknown AWS CLI error")


def exists_by_list(*args):
    """Lookup with a --query that yields a (possibly empty) list."""
    rc, out, err = aws(*args)
    if rc != 0:
        raise RuntimeError(err.splitlines()[-1] if err else "unknown AWS CLI error")
    return bool(json.loads(out or "[]"))


def tag_name(after):
    return (after.get("tags") or {}).get("Name")


def check(rc_type, after):
    """Return (description, exists) or None when this type is not checked."""
    name = after.get("name")
    if rc_type == "aws_iam_role" and name:
        return f"IAM role {name}", exists_by_error("iam", "get-role", "--role-name", name)
    if rc_type == "aws_eks_cluster" and name:
        return f"EKS cluster {name}", exists_by_error("eks", "describe-cluster", "--name", name)
    if rc_type == "aws_ecr_repository" and name:
        return f"ECR repository {name}", exists_by_error(
            "ecr", "describe-repositories", "--repository-names", name)
    if rc_type == "aws_cloudwatch_log_group" and name:
        return f"CloudWatch log group {name}", exists_by_list(
            "logs", "describe-log-groups", "--log-group-name-prefix", name,
            "--query", f"logGroups[?logGroupName=='{name}'].logGroupName")
    if rc_type == "aws_kms_alias" and name:
        return f"KMS alias {name}", exists_by_list(
            "kms", "list-aliases", "--query", f"Aliases[?AliasName=='{name}'].AliasName")

    # EC2 resources have generated IDs, so match them by their Name tag.
    n = tag_name(after)
    if not n:
        return None
    flt = f"Name=tag:Name,Values={n}"
    ec2 = {
        "aws_vpc": ("VPC", ["describe-vpcs", "--filters", flt, "--query", "Vpcs[].VpcId"]),
        "aws_subnet": ("subnet", ["describe-subnets", "--filters", flt, "--query", "Subnets[].SubnetId"]),
        "aws_internet_gateway": ("internet gateway", [
            "describe-internet-gateways", "--filters", flt, "--query", "InternetGateways[].InternetGatewayId"]),
        "aws_route_table": ("route table", [
            "describe-route-tables", "--filters", flt, "--query", "RouteTables[].RouteTableId"]),
        "aws_eip": ("Elastic IP", ["describe-addresses", "--filters", flt, "--query", "Addresses[].AllocationId"]),
        "aws_nat_gateway": ("NAT gateway", [
            "describe-nat-gateways", "--filter", flt,
            "--filter", "Name=state,Values=pending,available",
            "--query", "NatGateways[].NatGatewayId"]),
    }
    if rc_type in ec2:
        label, args = ec2[rc_type]
        return f"{label} tagged Name={n}", exists_by_list("ec2", *args)
    return None


def main(path):
    with open(path) as f:
        plan = json.load(f)

    conflicts, errors, checked = [], [], 0
    for rc in plan.get("resource_changes") or []:
        if rc["change"]["actions"] != ["create"]:
            continue
        after = rc["change"].get("after") or {}
        try:
            result = check(rc["type"], after)
        except (RuntimeError, OSError) as exc:
            errors.append(f'{rc["address"]}: could not verify ({exc})')
            continue
        if result is None:
            continue
        checked += 1
        description, found = result
        if found:
            conflicts.append(f'{rc["address"]}: {description} already exists in AWS')

    lines = [f"Preflight checked {checked} resource(s) the plan would create."]
    if conflicts:
        lines += ["", "ALREADY EXIST (not in Terraform state):", *[f"  - {c}" for c in conflicts],
                  "", "CI never imports resources or edits state. An administrator must either remove the",
                  "existing resource or run `terraform import` locally, then re-run this workflow."]
    if errors:
        lines += ["", "COULD NOT VERIFY (failing closed):", *[f"  - {e}" for e in errors]]
    if not conflicts and not errors:
        lines.append("No conflicting resources found.")

    report = "\n".join(lines)
    print(report)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write("### Preflight: existing resources\n```\n" + report + "\n```\n")

    if conflicts or errors:
        print("::error::preflight failed; nothing was uploaded and no approval is offered")
        return 1
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: preflight_existing_resources.py <plan.json>")
    sys.exit(main(sys.argv[1]))
