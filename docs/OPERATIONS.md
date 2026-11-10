# Operations guide: setup, permissions and workflows

> Detailed operating documentation for [terraform-aws-eks-cicd-platform](../README.md): bootstrap and setup commands, the Admin/CI permission boundary, both GitHub Actions workflows, required GitHub settings, cost and cleanup.

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
   ECR (immutable tags, scan on push)     S3 state bucket (bootstrap)
```

- Worker nodes run in **private** subnets only and reach the internet through one NAT gateway.
- The EKS API endpoint has both public and private access. The public endpoint is limited to the CIDRs you supply in `public_access_cidrs` (required, no default, `0.0.0.0/0` rejected).
- Nodes use the EKS-managed cluster security group. No custom security group has open inbound rules, and the VPC default security group is emptied.
- Single NAT gateway is a cost trade-off: if its AZ fails, private egress stops (nodes cannot pull from the internet, though ECR/EKS traffic needs the NAT too because no VPC endpoints are configured).

## Layout

```
terraform/
  bootstrap/        S3 state bucket (local state, run once)
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

### 1. Bootstrap the state bucket (once, local state)

The backend bucket must exist before the main configuration is initialized, so it
is created separately with local state.

```powershell
cd terraform/bootstrap
terraform init
terraform plan  -var "state_bucket_name=<globally-unique-bucket-name>"
terraform apply -var "state_bucket_name=<globally-unique-bucket-name>"
```

Keep the small local `terraform.tfstate` in `bootstrap/` safe (it is gitignored). The bucket has versioning, AES256 encryption, a full public access block, a TLS-only policy, and `prevent_destroy`.

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
terraform init -backend-config="bucket=<your-state-bucket>"
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
- Env/variables: `TF_VAR_public_access_cidrs`, `TF_VAR_tfstate_bucket_name`, and `terraform init -backend-config="bucket=..."`.

Two workflows: `.github/workflows/terraform.yml` (infrastructure, below) and `.github/workflows/eks-cicd.yml` (application, described after it).

## Terraform workflow (`infra Terraform`)

`.github/workflows/terraform.yml` is started **manually** (Actions tab → *infra Terraform* → Run workflow). It never runs on push or pull request.

1. **Terraform Plan** (automatic once started): checkout, AWS credentials from repository secrets, `aws sts get-caller-identity` (prints only the ARN), Terraform `1.16.2`, `init`, `validate`, `plan -out=tfplan`. The plan is **encrypted** (`gpg`, AES-256) and uploaded as an artifact with **1-day retention**.
2. **Terraform Apply** (`environment: production`): GitHub waits for a required reviewer to approve before the job starts. It then checks out the **same commit SHA**, downloads that exact artifact, verifies its SHA-256 (recorded by the plan job), decrypts it, and runs `terraform apply -auto-approve tfplan`. **No new plan is generated.** Terraform also refuses a saved plan if the state changed after it was made. Finally it runs `terraform output`.

Approving: open the run, click **Review deployments** on the waiting `Terraform Apply` job, tick `production`, **Approve and deploy** (or Reject).

Safeguards: runs are serialized (`concurrency: terraform-infra`, never cancelled); apply only runs on `main`; if the plan has no changes, nothing is uploaded and no approval is requested.

**Important: what CI may apply.** The CI identity has no IAM, KMS or EC2/VPC write permissions (Admin-only). The plan job checks the plan against an allow-list (EKS cluster/node group/access entries, ECR repository + lifecycle policy, the control-plane log group). If the plan changes anything else, it is still shown for review but is **not** uploaded and **no apply is offered**: apply those changes as an administrator. This means the first provisioning of the stack must be done by an admin, not by this workflow.

Required configuration:
- **Repository secrets:** `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (keys of the Terraform CI IAM user, created manually), `TF_PLAN_ENCRYPTION_KEY` (a long random passphrase, e.g. `openssl rand -base64 32`; never reuse another secret).
- **Repository variables:** `TFSTATE_BUCKET_NAME`, `PUBLIC_ACCESS_CIDRS` (JSON list, e.g. `["203.0.113.10/32"]`, never `0.0.0.0/0`).
- **Environment `production`** (Settings → Environments): required reviewers, optionally prevent self-review, deployment branches limited to `main`. It is shared with the application workflow.
- Settings that only exist in your local `terraform.tfvars` are not seen by CI. Anything non-default that CI cannot apply (e.g. `github_repository`) must not be set for CI, or the plan will propose admin-only changes.
- Plan artifacts are encrypted, but anyone who can read the repository can still download the ciphertext. Treat the passphrase and the AWS keys as sensitive, and move to OIDC when practical.

## Application CI/CD (GitHub Actions)

The application pipeline is `.github/workflows/eks-cicd.yml`.

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

**For a human/admin running bootstrap:** S3 bucket creation and configuration (`s3:CreateBucket`, `PutBucketVersioning`, `PutEncryptionConfiguration`, `PutBucketPublicAccessBlock`, `PutBucketOwnershipControls`, `PutLifecycleConfiguration`, `PutBucketPolicy`, plus the matching `Get*`).

**For the first apply of the main stack, and any change to IAM, KMS, or EC2/VPC resources:** use an administrator-level identity. See [Admin / CI permission boundary](#admin--ci-permission-boundary) below. CI after provisioning can plan the whole stack and manage only the EKS cluster/node group, ECR repository and control-plane log group.

**For the GitHub Actions user** (policy `<project>-github-actions-deploy`, defined in `modules/iam/github_deploy_policy.tf`):

| Area | Scope |
|---|---|
| S3 state | List on the bucket; Get/Put/Delete only on the state key and its `.tflock` |
| EC2/VPC | **Read-only** (`ec2:Describe*`, region-restricted). No VPC, subnet, gateway, NAT, Elastic IP, route, security-group or launch-template changes, and no `CreateTags`/`DeleteTags` |
| EKS | Cluster, node group, access entry actions on `<project>-*` only |
| IAM | **Read-only** on roles named `<project>-*` (no create/update/delete, no trust-policy, inline or attached-policy writes, which would let CI escalate to admin); `PassRole` only on the exact EKS cluster role and node role ARNs, and only to EKS; service-linked role creation for EKS/nodegroup/autoscaling; read-only on its own user/policy |
| KMS | Describe/rotation-status/key-policy/tag reads and `CreateGrant` on the single secrets key only; no key creation, policy changes or deletion |
| Logs | Manage only `/aws/eks/<project>-*` log groups |
| ECR | Manage only the one repository (Terraform management, not image push) |

The deploy identity has no IAM write access and no EC2/VPC write access. It can still create, change and delete the EKS cluster and node group (including access entries and public endpoint settings) and the ECR repository, so treat its keys as sensitive and move to OIDC (`modules/iam/github_oidc.tf.example`). Pushing images from CI will need a separate ECR push policy later.

### Admin / CI permission boundary

| | Admin (human, outside CI) | GitHub Actions CI |
|---|---|---|
| IAM roles, policies, CI user | create/change (`modules/iam`) | read-only |
| KMS secrets key | create/change | read, plus `CreateGrant` on that one key |
| EC2/VPC (VPC, subnets, IGW, NAT, EIPs, routes, security groups, launch templates, tags) | full, via the `<project>-admin-ec2-vpc` policy or equivalent | `ec2:Describe*` only |
| EKS cluster / node group | full | create/update/delete, scoped to `<project>-*` |
| ECR repository, control-plane log group | full | manage, scoped to the one repo / `/aws/eks/<project>-*` |
| State bucket | bootstrap | read/write only the state object and its lock |
| `iam:PassRole` | any | exact cluster-role and node-role ARNs, only to EKS |

Consequences:

- `modules/iam/admin_policy.tf` defines the admin EC2/VPC permission set as a managed policy (`admin_ec2_vpc_policy_arn` output). **Terraform does not attach it to anyone.** Attach it (or `AdministratorAccess`) to your admin role or group yourself. It covers EC2/VPC only; initial provisioning also needs IAM, KMS, EKS, ECR, CloudWatch Logs and S3 permissions, which is why an administrator-level identity is assumed. Never attach it to the CI user.
- Because CI cannot write EC2, a change to `modules/vpc` or to the node launch template in `modules/eks` must be applied by an admin. A CI `apply` containing such a change fails partway. Review the plan and run those applies as admin.
- The identity that creates the cluster becomes its Kubernetes cluster admin (`bootstrap_cluster_creator_admin_permissions`). Run the first apply as the admin, not as CI.

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

ECR has `force_delete = false`: delete images in the repository first. The state bucket has `prevent_destroy`; to remove it, empty all object versions, delete the `prevent_destroy` block, then destroy in `bootstrap/`.
