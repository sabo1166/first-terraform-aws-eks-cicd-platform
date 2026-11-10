# Operations guide: setup, permissions and workflows

> Detailed operating documentation for [terraform-aws-eks-cicd-platform](../README.md): setup commands, the Admin/CI permission boundary, both GitHub Actions workflows, required GitHub settings, cost and cleanup.

Terraform foundation for deploying a Kubernetes application on Amazon EKS, with
images in Amazon ECR and CI through GitHub Actions.

> **Cost warning.** This stack creates billable resources: an EKS control plane,
> two EC2 worker nodes, a NAT gateway, an Elastic IP, EBS volumes, CloudWatch
> logs and a KMS key. It costs money for every hour it exists, even when idle.
> Destroy it when you are not using it (see [Cleanup](#cleanup)).

## Architecture

```
                         Internet
                            |
                    [Internet Gateway]
                            |
   VPC 10.0.0.0/16  ---------------------------------------------
   |  us-east-1a                          us-east-1b            |
   |  public  10.0.0.0/24  [NAT GW + EIP]  public 10.0.1.0/24   |
   |  private 10.0.16.0/20 [worker node]   private 10.0.32.0/20 [worker node]
   |        \__ EKS managed node group (2 x t3.medium) __/       |
   |  EKS control plane ENIs in the private subnets              |
   ---------------------------------------------------------------
   ECR (immutable tags, scan on push)     S3 state bucket (manual)
```

- Worker nodes run in **private** subnets only and reach the internet through one NAT gateway.
- The EKS API endpoint has both public and private access. The public endpoint is limited to the CIDRs you supply in `public_access_cidrs` (required, no default, `0.0.0.0/0` rejected).
- Nodes use the EKS-managed cluster security group. No custom security group has open inbound rules, and the VPC default security group is emptied.
- Single NAT gateway is a cost trade-off: if its AZ fails, private egress stops (nodes cannot pull from the internet, though ECR/EKS traffic needs the NAT too because no VPC endpoints are configured).

## Layout

```
terraform/
  bootstrap/        reference only, NOT used (the state bucket was created manually)
  modules/vpc|eks|ecr|iam
  main.tf providers.tf variables.tf outputs.tf versions.tf backend.tf
  backend.hcl.example  terraform.tfvars.example
```

## Modules

| Module | Creates | Key inputs | Key outputs |
|---|---|---|---|
| `vpc` | VPC, 2 public + 2 private subnets, IGW, 1 NAT GW + EIP, route tables, K8s discovery tags, locked default SG | `vpc_cidr`, `availability_zones`, `public_subnets`, `private_subnets` | `vpc_id`, `public_subnet_ids`, `private_subnet_ids` |
| `eks` | Cluster (API access entries, all 5 log types, KMS secret encryption using the key from `iam`), CloudWatch log group, managed node group (IMDSv2, encrypted gp3, private subnets), optional extra access entries | `kubernetes_version`, `public_access_cidrs`, node sizing | `cluster_name`, `cluster_endpoint`, `cluster_security_group_id` |
| `ecr` | Private repo, `IMMUTABLE` tags, scan on push, KMS encryption, lifecycle rule (untagged > 14 days expire) | `repository_name` | `repository_url` |
| `iam` | EKS cluster role (plus inline KMS policy), node role (3 AWS-managed policies), EKS secrets KMS key, GitHub Actions IAM user (no keys) and a separate deploy policy | `project_name`, `cluster_name`, state bucket/key, ECR name | role ARNs, KMS key ARN, deploy policy ARN |

Kubernetes version default is `1.35`. 1.34 leaves EKS standard support on 2026-12-02; 1.35 runs to 2027-03-27 ([EKS version calendar](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html)). Re-check the calendar before deploying.

The `first-k8s-project` Kubernetes namespace is **not** created by Terraform. Create it after the cluster exists: `kubectl create namespace first-k8s-project`.

## Prerequisites

- Terraform >= 1.10 (tested here with 1.16.2; AWS provider locked at 5.100.0).
- AWS CLI and an AWS identity with the permissions in [AWS permissions](#aws-permissions).
- Quota/capacity for 2 x t3.medium and 1 Elastic IP in `us-east-1`.
- `kubectl` for cluster access afterwards.

Never commit credentials, `*.tfstate`, `*.tfplan` or `*.tfvars` (all gitignored).

## Setup

### 1. State bucket (created manually in the AWS Console)

The remote-state bucket `moh-terraform-state-2026-uniq` (us-east-1) **already exists**. It was created manually through the AWS Console, not by Terraform. The main configuration only uses it: `terraform/backend.tf` names the bucket and Terraform never creates it.

`terraform/bootstrap/` is **not needed for this bucket and must not be run**. It is kept only as a record of the intended bucket settings and as a starting point if a replacement bucket is ever needed. Running it would try to create a bucket that already exists.

Check these settings in the Console (a manually created bucket does not get them all by default):
- **Bucket Versioning: Enabled** (new buckets have it off; it lets you recover older state).
- Default encryption: on (SSE-S3 / AES-256).
- **Block all public access: on.**
- Optional: a bucket policy that denies requests without TLS.

### 2. Configure `public_access_cidrs`

This list decides who can reach the Kubernetes API from the internet. It is required.

```powershell
# your current public IP
(Invoke-RestMethod https://checkip.amazonaws.com).Trim()
```

Use it with `/32`, e.g. `["203.0.113.10/32"]`:

- Locally: put it in `terraform/terraform.tfvars` (copy from `terraform.tfvars.example`).
- In CI: set `TF_VAR_public_access_cidrs` as JSON, e.g. `["203.0.113.10/32"]`, as a GitHub repository variable.

Terraform itself only calls AWS APIs, so CI does not need API-server access for plan/apply. GitHub-hosted runner IPs change constantly and cannot be listed safely; if a later pipeline must run `kubectl`, use a self-hosted runner with a fixed egress IP, or reach the private endpoint from inside the VPC.

### 3. Initialize and validate the main configuration

```powershell
cd terraform
Copy-Item terraform.tfvars.example terraform.tfvars   # then edit the values
terraform init
terraform fmt -recursive
terraform validate
terraform plan -out=tfplan
```

Review the plan carefully before any apply. `terraform apply` is intentionally not part of this repository's automation yet.

## Security notes

- No credentials in code; the provider uses the standard credential chain.
- Secrets in Kubernetes are envelope-encrypted with a customer KMS key (rotation on).
- Nodes: private subnets, IMDSv2 required, hop limit 1, encrypted gp3 volumes, no SSH key.
- All five EKS control-plane log types go to CloudWatch (30-day retention).
- State: S3 versioning, encryption, public access block, TLS-only, native lockfile.
- ECR: immutable tags, scan on push, KMS encryption.
- Not included (possible later): VPC endpoints, VPC flow logs, S3 access logging, a CMK for the state bucket.

## GitHub Actions

Compatible with a workflow that runs `fmt`, `init`, `validate` and `plan`. The workflow needs:

- Secrets: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (keys for the Terraform-managed IAM user, created manually in the console/CLI; Terraform never creates them).
- Env/variables: `TF_VAR_public_access_cidrs`. The state bucket is fixed in `backend.tf`; `terraform init` needs no extra arguments.

Two workflows: `.github/workflows/terraform.yml` (infrastructure, below) and `.github/workflows/eks-cicd.yml` (application, described after it).

## Terraform workflow (`infra Terraform`)

`.github/workflows/terraform.yml` is started **manually** (Actions tab → *infra Terraform* → Run workflow). It never runs on push or pull request.

1. **Terraform Plan** (automatic once started): checkout, AWS credentials from repository secrets, `aws sts get-caller-identity` (prints only the ARN), Terraform `1.16.2`, `init`, `validate`, `plan -out=tfplan`. The saved plan is uploaded as an artifact with **1-day retention** and its SHA-256 is recorded. **The artifact is not encrypted** (see the warning below).
2. **Terraform Apply** (`environment: production`): GitHub waits for a required reviewer to approve before the job starts. It then checks out the **same commit SHA**, downloads that exact artifact, verifies its SHA-256 (recorded by the plan job), and runs `terraform apply -auto-approve tfplan`. **No new plan is generated.** Terraform also refuses a saved plan if the state changed after it was made. Finally it runs `terraform output`.

Approving: open the run, click **Review deployments** on the waiting `Terraform Apply` job, tick `production`, **Approve and deploy** (or Reject).

Safeguards: runs are serialized (`concurrency: terraform-infra`, never cancelled); apply only runs on `main`; if the plan has no changes, nothing is uploaded and no approval is requested.

**Delete guard (apply job).** Right before `terraform apply`, the apply job re-checks the saved plan (`terraform show -json`) and fails if any resource has a `delete` action (delete, delete+create, create+delete), or if the plan creates an EKS cluster with `bootstrap_cluster_creator_admin_permissions` not `false` (the creating CI identity would become Kubernetes cluster-admin). It fails before anything is applied. Note this check runs **after** the approval, so a plan containing a delete or replace is still offered for approval and is then refused; read the plan before approving.

**No resource-type allow-list.** The plan job used to block plans that changed resource types CI wasn't meant to apply. That check was removed: any plan with changes is encrypted, uploaded and offered for approval, and **the human review at the `production` approval is what decides what gets applied.** What CI can actually change is now limited only by the AWS permissions of the CI IAM user (see [AWS permissions](#aws-permissions)). If an approved plan includes something the CI user may not do (for example creating the CI user itself, any IAM policy, or changing an existing VPC resource), `terraform apply` **fails partway**: resources applied before the failure stay applied and the state records them. So before approving, check that every resource in the plan is one the CI user can create or change; if not, do not approve and have an administrator apply it. The first provisioning needs a one-time admin step first, see [Initial creation through CI](#initial-creation-through-ci).

### Root cause of the "S3 bucket ... does not exist" init failure
`terraform init` failed with `S3 bucket "moh-terraform-state-2026-unique" does not exist.` The real state bucket is `moh-terraform-state-2026-uniq`, but the repository hardcoded the wrong name (`...-unique`) in `terraform/backend.tf`, the workflow, variable defaults and docs. The backend block cannot use variables and the workflow does not read a `TFSTATE_BUCKET_NAME` variable, so setting that GitHub variable had no effect. The name is now `moh-terraform-state-2026-uniq` everywhere. No state was migrated: the old name never existed as a bucket.

If you ever change the bucket name again, update all of: `terraform/backend.tf`, `TF_VAR_tfstate_bucket_name` in `terraform.yml`, `tfstate_bucket_name` in `terraform/variables.tf`, and the example files. On a machine with an older `.terraform/` directory, `terraform init` may ask for `-reconfigure`; do that only after confirming no state lives in the old location.

### Required S3 IAM permissions for the state backend
The CI IAM user (and any admin running Terraform locally) needs, on the state bucket `moh-terraform-state-2026-uniq`:
- `s3:ListBucket` and `s3:GetBucketLocation` on `arn:aws:s3:::moh-terraform-state-2026-uniq`
- `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject` on `arn:aws:s3:::moh-terraform-state-2026-uniq/eks-cicd-platform/terraform.tfstate` and `.../eks-cicd-platform/terraform.tfstate.tflock` (the `.tflock` object is the native S3 lock file; `DeleteObject` is needed to release it)

These come from `terraform/modules/iam/github_deploy_policy.tf` (statements `StateBucketList` and `StateObjects`), which is built from `tfstate_bucket_name` and `tfstate_key`.

**An administrator must update the IAM policy before CI can use the renamed bucket.** The deployed CI policy was most likely created with the old name `...-unique`, so until it is updated the CI user will get AccessDenied on `terraform init`. Steps (administrator, outside CI):
1. Run `terraform plan` locally with admin credentials and confirm the only change is the deploy policy document (bucket name in the two state statements).
2. Review it, then apply it as an administrator (this workflow cannot: IAM writes are Admin-only, and it is also admin-only because the plan changes `aws_iam_policy`).
3. Re-run the `infra Terraform` workflow.

### How the `production` environment approval works
The apply job declares `environment: production`. GitHub pauses that job before any step runs until a **required reviewer** approves. This is the human approval; `workflow_dispatch` itself is only the trigger, not an approval. The approval gate exists **only if you configure it** in GitHub (the repository files cannot enforce it):
1. Repository **Settings → Environments → New environment** (or open `production`).
2. Enable **Required reviewers** and add at least one person (up to 6). Private repositories need GitHub Pro/Team/Enterprise for this.
3. Optionally enable **Prevent self-review** (only helps with 2 or more reviewers).
4. Under **Deployment branches and tags** choose **Selected branches** and allow only `main`.
5. Verify: run the workflow and check that the `4 - Terraform Apply` job shows "Waiting" with a **Review deployments** button before it starts.

### Safe deployment procedure
1. Make sure the code is on `main` and the IAM policy update above is done.
2. Actions → *infra Terraform* → Run workflow on `main`.
3. Read the `3 - Terraform Plan` job output (and the preflight summary). Look for any delete or replace, and for resources the CI user is not allowed to create or change (the CI user, IAM policies, the permissions boundary, changes to existing VPC/IAM/KMS resources). If there are any, reject and hand the plan to an administrator.
4. Only if the plan is exactly what you expect, open the waiting apply job → **Review deployments** → approve. Otherwise reject.
5. Check the job's `terraform output` and confirm the result. Plan artifacts expire after 1 day, so a plan not approved in time must be re-run.

Required configuration:
- **Repository secrets:** `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (keys of the Terraform CI IAM user, created manually). The former `TF_PLAN_ENCRYPTION_KEY` secret is **no longer used**; it can be deleted from the repository secrets.
- **Repository variables:** `PUBLIC_ACCESS_CIDRS` (JSON list, e.g. `["203.0.113.10/32"]`, never `0.0.0.0/0`). The state bucket is no longer a variable: it is fixed as `moh-terraform-state-2026-uniq` in `terraform/backend.tf` and in the workflow (`TF_VAR_tfstate_bucket_name`).
- **Environment `production`** (Settings → Environments): required reviewers, optionally prevent self-review, deployment branches limited to `main`. It is shared with the application workflow.
- Settings that only exist in your local `terraform.tfvars` are not seen by CI. Anything non-default that CI cannot apply (e.g. `github_repository`) must not be set for CI, or the plan will propose admin-only changes.
- **The saved plan artifact is NOT encrypted and may contain sensitive values in plain text** (a Terraform plan can include resource attributes, and values marked sensitive are still stored in the plan file). Anyone who can read this repository's Actions artifacts can download it for the 1-day retention period. Keep the repository **private**, restrict who has read access, and never make it public while using this workflow. The workflow never prints the plan contents and removes the plan from the runner at the end, but the uploaded artifact stays until it expires. The SHA-256 check only detects a swapped or altered artifact; it does not hide the contents. Treat the AWS keys as sensitive too, and move to OIDC when practical.

## Application CI/CD (GitHub Actions)

`.github/workflows/eks-cicd.yml` builds the container image and deploys it to EKS, with a **manual approval** before anything touches the cluster.

| Job | Runs on | What it does | AWS access |
|---|---|---|---|
| `validate` | every push and pull request | Terraform fmt/validate (root + bootstrap), Dockerfile lint, manifest schema check, rejects cluster-scoped manifests, runs `app/test.sh` if present | none |
| `build-and-push` | every push and pull request | builds the image, scans it with Trivy (fails on HIGH/CRITICAL), then **only on a push to `main`** pushes it to ECR tagged with the commit SHA | OIDC push-only role, `main` only |
| `deploy` | push to `main` only | declares `environment: production`, so GitHub **waits for a reviewer**; after approval it applies the manifests with the approved image **digest** and waits for the rollout | OIDC deploy role, `production` environment only |

Pull requests run `validate` and the build/scan, and can never reach `deploy` (job condition) or assume either AWS role (the OIDC trust policies reject pull-request tokens).

### How you approve a deployment
1. Push or merge to `main`. The workflow run shows `validate` and `build-and-push` finishing, then `deploy` with a yellow **Waiting** state and a banner "**production** needs approval".
2. GitHub notifies the required reviewers (email/web notification). Open the run, click **Review deployments**, tick `production`, optionally comment, then **Approve and deploy** (or **Reject**).
3. Only then does the `deploy` job start.

**Before approval:** code is validated, the image is built, scanned and pushed to ECR (immutable tag = commit SHA). The cluster is untouched; the `deploy` job has not started, no deploy credentials exist, and the deploy role cannot be assumed because its trust policy only accepts jobs that already passed the environment's approval.
**After approval:** the job assumes the deploy role through OIDC (short-lived credentials, no secrets), confirms the image digest exists in ECR, writes a kubeconfig, applies the manifests into the one allowed namespace with `image:` set to `repo@sha256:...`, and waits for `kubectl rollout status`. A failed rollout fails the job (roll back by hand: `kubectl -n <ns> rollout undo deployment/<name>`).

### One-time setup
1. **Administrator applies the IAM pieces** (needs IAM write access; CI cannot do this). Set `github_repository = "owner/name"` in `terraform.tfvars` (and `github_oidc_provider_arn` if the account already has a GitHub OIDC provider), review the plan, then apply as admin. This creates the OIDC provider (if needed), the two roles and a namespace-scoped EKS access entry. Read the role ARNs from the outputs `github_ecr_push_role_arn` and `github_eks_deploy_role_arn`.
2. **Create the namespace** (admin): `kubectl create namespace first-k8s-project`. Terraform does not manage it and the deploy role cannot create it.
3. **Add the application** (not included in this repo yet): `app/Dockerfile` (build context `app/`), optional `app/test.sh`, and namespaced manifests in `k8s/*.yaml` using `image: ${IMAGE}` for the container. The workflow fails with a clear message if `app/Dockerfile` or `k8s/` is missing.
4. **Configure GitHub manually** (see below).
5. **Make the EKS API reachable from the deploy runner.** The API's public endpoint only accepts `public_access_cidrs`, and GitHub-hosted runner IPs are not stable. Use a self-hosted runner with a fixed egress IP listed in `public_access_cidrs`, or one inside the VPC (private endpoint), and set its label in `DEPLOY_RUNNER_LABEL`. Do not run pull-request jobs on that runner. Otherwise the deploy job cannot connect.

### GitHub settings you must configure manually
**Settings → Environments → New environment → `production`:**
- **Required reviewers:** add yourself (and/or others). This is the approval gate. Note: environment reviewers on *private* repositories require GitHub Pro/Team/Enterprise.
- **Prevent self-review:** enable if more than one reviewer exists.
- **Deployment branches and tags:** "Selected branches" → `main` only.
- **Environment variables:** `AWS_DEPLOY_ROLE_ARN` (output `github_eks_deploy_role_arn`), `EKS_CLUSTER_NAME`, `K8S_NAMESPACE` (`first-k8s-project`), `K8S_DEPLOYMENT` (the Deployment name in your manifests), optional `DEPLOY_RUNNER_LABEL`.
- Do **not** add AWS keys. The pipeline uses no AWS secrets.

**Settings → Secrets and variables → Actions → Variables (repository):** `AWS_REGION` (`us-east-1`), `ECR_REPOSITORY` (the repository name, default `first-k8s-project`), `AWS_PUSH_ROLE_ARN` (output `github_ecr_push_role_arn`). These are not secrets.

**Settings → Branches → rule for `main`:** require pull requests and the `validate` status check, so only reviewed code can reach `main` and trigger a deployment. Also set **Settings → Actions → General → Workflow permissions** to read-only.

### IAM permissions CI requires (OIDC, no long-lived keys)
| Role (trust) | Permissions |
|---|---|
| `<project>-gha-ecr-push`: only `repo:<owner/repo>:ref:refs/heads/main` | `ecr:GetAuthorizationToken` (account-wide, not scopable); on the one repository: `BatchCheckLayerAvailability`, `InitiateLayerUpload`, `UploadLayerPart`, `CompleteLayerUpload`, `PutImage`, `DescribeImages`. No pull, delete or repository administration |
| `<project>-gha-eks-deploy`: only `repo:<owner/repo>:environment:production` | `eks:DescribeCluster` on the cluster; `ecr:DescribeImages` on the repository. Kubernetes access via EKS access entry with the `AmazonEKSEditPolicy` scoped to **one namespace** (can change workloads and read Secrets in that namespace; no cluster-scoped objects, cannot create namespaces) |

These are separate from the Terraform-management identity (`modules/iam/github_actions.tf`) and from Admin permissions: neither role can write IAM, KMS or EC2, and neither is AdministratorAccess. Without OIDC you would need two separate long-lived IAM users stored as secrets; this setup avoids that.

## AWS permissions

**For the state bucket:** it was created manually in the AWS Console, so no Terraform permissions are needed to create it. `terraform/bootstrap` is not run.

**For the admin-managed layer** (CI user, both CI policies, the permissions boundary, the admin EC2/VPC policy): an administrator-level identity, applied once. CI can never change these. See [Admin / CI permission boundary](#admin--ci-permission-boundary) below.

**For the first creation of the stack:** CI can now create the network, the two EKS roles, the KMS key and the node launch template, **after** the admin layer exists (see [Initial creation through CI](#initial-creation-through-ci)). After that, CI can plan the whole stack and apply EKS, ECR and log-group changes.

**For the GitHub Actions user** the permissions come from two managed policies, both admin-managed:
- `<project>-github-actions-deploy` (`modules/iam/github_deploy_policy.tf`): day-to-day permissions.
- `<project>-github-actions-create` (`modules/iam/github_deploy_create_policy.tf`): create-only permissions for first provisioning. It is a separate policy because one managed policy is limited to 6,144 characters.

| Area | Scope |
|---|---|
| S3 state | List on the bucket; Get/Put/Delete only on the state key and its `.tflock` |
| EC2/VPC read | `ec2:Describe*`, region-restricted |
| EC2/VPC create (create policy) | `CreateVpc/Subnet/InternetGateway/RouteTable/NatGateway/LaunchTemplate`, `AllocateAddress`: only when the request carries tag `Project=<project>`, region-restricted. `CreateTags` only as part of those creations. `Modify*/Attach*/CreateRoute/ReplaceRoute/AssociateRouteTable/CreateLaunchTemplateVersion` only on resources tagged `Project=<project>`. **No Delete*, Release*, Detach*, Disassociate*.** |
| EKS | Cluster, node group, access entry actions on `<project>-*` only |
| IAM read | Roles named `<project>-*`, and its own user/policies/boundary (read-only) |
| IAM create (create policy) | `CreateRole` and `TagRole` **only** on the exact EKS cluster role and node role ARNs, and `CreateRole` only when the permissions boundary `<project>-eks-role-boundary` is set. `AttachRolePolicy` only for the 4 AWS-managed policies those roles use. `PutRolePolicy` only on the cluster role (the boundary caps what it can grant). Explicit **deny** on removing or replacing the boundary |
| IAM self-protection | Explicit **deny** on any write to the CI user, both CI policies, the admin policy and the boundary (including new policy versions, attaching policies, access keys) |
| IAM other | `PassRole` only on the exact two EKS role ARNs, only to EKS; service-linked roles for EKS/nodegroup/autoscaling |
| KMS | Read, rotation status, `CreateGrant` on keys tagged `Project=<project>`. Create (create policy): `CreateKey`+`TagResource` only with request tags `Project=<project>` and `ManagedBy=terraform`; `EnableKeyRotation` and alias target only on tagged keys; `CreateAlias` only for `alias/<cluster>-secrets`. **No PutKeyPolicy, no ScheduleKeyDeletion** |
| Logs | Manage only `/aws/eks/<project>-*` log groups |
| ECR | Manage only the one repository (Terraform management, not image push) |

**Unavoidable wildcards (each documented in the `.tf` files):**
- `Resource "*"` for `ec2:Create*`/`AllocateAddress` and `kms:CreateKey`/`kms:TagResource`: a new resource has no ARN yet. Mitigation: required `Project`/`ManagedBy` request tags and region.
- `vpc/*`, `subnet/*`, `route-table/*`, `key/*`, ...: AWS generates the IDs. Mitigation: the `Project` resource tag condition.
- `security-group/*` for `RevokeSecurityGroupIngress/Egress` and tagging: `aws_default_security_group` must empty the VPC's untagged default group, so it can't be scoped by tag. It can only remove rules, never open traffic.
- In the boundary: `ec2:*` and `elasticloadbalancing:*` (region-limited), because the AWS-managed EKS policies use many such actions that AWS changes over time. It is a ceiling, not a grant.

The deploy identity can still call EKS/ECR/log-group delete APIs directly (the IAM policy grants them for operations). The apply job's delete guard refuses plans that contain them, but treat the CI keys as sensitive and move to OIDC (`modules/iam/github_oidc.tf.example`). Pushing images from CI will need a separate ECR push policy later.

### Admin / CI permission boundary

| | Admin (human, outside CI) | GitHub Actions CI |
|---|---|---|
| CI IAM user, both CI policies, permissions boundary, admin EC2/VPC policy | create/change (`modules/iam`), once | **never** (explicitly denied in IAM; an approved plan that includes them fails at apply) |
| EKS cluster and node IAM roles | any | create only, with the boundary attached |
| KMS secrets key | create/change | create only (tag/region-conditioned); read, `CreateGrant` |
| VPC, subnets, IGW, NAT, EIP, route tables, default SG, launch template | full, via `<project>-admin-ec2-vpc` or equivalent | create only (launch template may also be updated); no deletes |
| EKS cluster / node group | full | create/update; deletes refused by the apply-job guard |
| ECR repository, control-plane log group | full | manage, scoped to the one repo / `/aws/eks/<project>-*` |
| State bucket | created manually (Console) | read/write only the state object and its lock |
| `iam:PassRole` | any | exact cluster-role and node-role ARNs, only to EKS |

What the CI user's IAM permissions cover (this is the only technical limit now that the workflow allow-list is gone; see [AWS permissions](#aws-permissions)):
- **Create and update:** EKS cluster, node group, access entries and policy associations, ECR repository and lifecycle policy, the control-plane log group, the node launch template.
- **Create only:** VPC, subnets, internet gateway, NAT gateway, Elastic IP, route tables and associations, the default security group lock-down, the KMS key and alias, and the two EKS IAM roles (with the permissions boundary).
- **Not possible for CI:** creating or changing the CI user, any IAM policy, the boundary, the OIDC provider or OIDC roles; key policies; any delete in EC2/IAM/KMS.

Consequences:

- `modules/iam/admin_policy.tf` defines the admin EC2/VPC permission set for humans (`admin_ec2_vpc_policy_arn` output). **Terraform does not attach it to anyone.** Attach it (or `AdministratorAccess`) to your admin role or group yourself. Never attach it to the CI user.
- Changing an existing VPC/IAM/KMS resource (anything other than create) is an administrator job. The workflow no longer filters these out, so an approved plan containing them fails partway at apply; reject such plans at the approval.
- **Kubernetes cluster-admin and CI:** with the current setting (`bootstrap_cluster_creator_admin_permissions = true`), the apply job's re-check **refuses** any plan that creates the EKS cluster, so the cluster must be created by an administrator until the setting is changed. See the proposal in [Initial creation through CI](#initial-creation-through-ci).

### Initial creation through CI

**Existing-resource protection.** The plan job runs a read-only preflight (`.github/scripts/preflight_existing_resources.py`) on every plan that creates resources. It looks up the IAM roles, EKS cluster, ECR repository, log group, KMS alias, and VPC/subnet/gateway/route table/Elastic IP/NAT gateway (matched by `Name` tag) and fails the job if one already exists, or if it can't verify (fail closed). It never imports anything and never touches Terraform state. If it reports a conflict, an administrator removes the manual resource or runs `terraform import` locally; then re-run the workflow.

**Required one-time admin step (before the first CI run).** The CI user and both CI policies must exist before CI can create anything, and the permissions boundary must exist before CI can create the EKS roles. Because these are admin-only, an administrator applies them from a local machine with admin credentials (same S3 backend, no migration), then CI creates the rest:
1. `terraform init` and `terraform plan -out=admin.tfplan` with the same variable values CI uses (`public_access_cidrs` etc.; do not set `github_repository`).
2. Review. The admin layer is `module.iam.aws_iam_policy.ci_role_boundary`, `aws_iam_user.github_actions`, `aws_iam_policy.github_deploy`, `aws_iam_policy.github_deploy_create`, both `aws_iam_user_policy_attachment` resources and `aws_iam_policy.admin_ec2_vpc`. Applying the full stack as admin is also fine; applying only this layer requires `-target`, which is an administrator decision.
3. Create the CI user's access keys manually (Terraform never does) and store them as the GitHub secrets.
4. Run the `infra Terraform` workflow. Expected: the plan shows creates for the network, roles, KMS key and launch template.

**Proposal, not implemented: how CI could also create the EKS cluster safely.** Today the cluster uses `bootstrap_cluster_creator_admin_permissions = true`, so whoever creates it (CI) would become Kubernetes cluster-admin; the apply job's re-check therefore refuses it. The secure alternative:
1. Add a variable (e.g. `cluster_admin_principal_arn`, an IAM role/user of a human administrator) and an `aws_eks_access_entry` + `AmazonEKSClusterAdminPolicy` association for it through `additional_access_entries`.
2. Set `bootstrap_cluster_creator_admin_permissions = false` in `modules/eks/main.tf`.
3. The apply-job re-check then allows CI to create the cluster, and CI holds no Kubernetes permissions.
Caveat: this setting forces replacement of an existing cluster, so it must be done before the cluster is created. It needs your decision and the administrator principal ARN.

**Not verified.** None of the new permissions or the tag-based EC2/KMS conditions have been exercised against a real AWS account. Expect to refine them after a test run; the plan job and the IAM policy are meant to fail closed, so a missing permission stops the apply rather than widening access.

## Estimated cost (rough, us-east-1, verify on the AWS pricing pages)

| Item | Approx. |
|---|---|
| EKS control plane | ~$0.10/hour (~$73/month). Versions in extended support cost more |
| 2 x t3.medium on-demand | ~$0.0416/hour each (~$61/month total) |
| NAT gateway | ~$0.045/hour (~$33/month) plus per-GB processing |
| Public IPv4 / EIP | ~$0.005/hour each |
| EBS 2 x 30 GiB gp3 | a few dollars/month |
| CloudWatch logs, KMS key, ECR storage, S3 state | small, usage-based |

Expect very roughly **$170-190/month** while running. Treat these as estimates, not quotes.

## Cleanup

Order matters; remove Kubernetes-created resources first (load balancers, volumes) or VPC deletion will hang.

```powershell
kubectl delete namespace first-k8s-project      # removes any LoadBalancers it created
cd terraform
terraform plan -destroy                          # review first
terraform destroy                                # only when you are sure
```

ECR has `force_delete = false`: delete images in the repository first. The state bucket was created manually and is not managed by Terraform: delete it in the AWS Console only after the infrastructure that uses it is gone (empty all object versions first).
