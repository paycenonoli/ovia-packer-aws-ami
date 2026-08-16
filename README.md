# OVIA Packer → Ansible → Terraform → Jenkins AWS AMI Deployment

## Overview

This project demonstrates an end-to-end AWS infrastructure and deployment workflow in which:

1. **Packer** creates an immutable Ubuntu AMI.
2. **Ansible** configures the temporary EC2 instance used by Packer.
3. **Packer** snapshots that configured instance into a reusable AMI.
4. **Terraform** deploys the AMI through an AWS Launch Template and Auto Scaling Group.
5. **Jenkins** orchestrates the complete workflow.
6. **Terraform remote state** is stored in Amazon S3 with state locking.
7. A Jenkins approval gate is used before the new AMI is deployed.
8. The Auto Scaling Group replaces the old application instance with an instance launched from the new AMI.

The resulting deployment flow is:

```text
GitHub
   |
   v
Jenkins
   |
   +----------------------+
   |                      |
   v                      v
Packer                 Terraform
   |                      |
   v                      v
Temporary EC2        S3 Remote State
   |
   v
Ansible
   |
   v
Configured EC2
   |
   v
Immutable AMI
   |
   v
Terraform Launch Template
   |
   v
Auto Scaling Group
   |
   v
New EC2 Instance
```

---

# 1. Project Architecture

```text
                         +------------------+
                         |     GitHub       |
                         | ovia-packer-aws- |
                         |       ami        |
                         +--------+---------+
                                  |
                                  | Git/SSH
                                  v
                         +------------------+
                         |     Jenkins      |
                         |    t3.small      |
                         +--------+---------+
                                  |
                 +----------------+----------------+
                 |                                 |
                 v                                 v
          +-------------+                   +-------------+
          |   Packer    |                   |  Terraform  |
          +------+------+                   +------+------+
                 |                                 |
                 | creates temporary EC2           |
                 v                                 |
          +-------------+                          |
          | Temporary   |                          |
          | EC2 Instance|                          |
          +------+------+                          |
                 |                                 |
                 | SSH                                  |
                 v                                 |
          +-------------+                          |
          |   Ansible   |                          |
          |  Playbook   |                          |
          +------+------+                          |
                 |                                 |
                 v                                 |
          +-------------+                          |
          | Configured  |                          |
          | EC2         |                          |
          +------+------+                          |
                 |                                 |
                 | snapshot                       |
                 v                                 |
          +-------------+                          |
          | Immutable   |                          |
          | AMI         |--------------------------+
          +-------------+            ami_id
                                             |
                                             v
                                    +----------------+
                                    | Launch Template|
                                    +-------+--------+
                                            |
                                            v
                                    +----------------+
                                    | Auto Scaling   |
                                    | Group          |
                                    | min=1 max=1    |
                                    +-------+--------+
                                            |
                                            v
                                    +----------------+
                                    | Application EC2|
                                    | Running        |
                                    +----------------+
```

---

# 2. Repository Structure

The repository is organized approximately as follows:

```text
ovia-packer-aws-ami/
├── Jenkinsfile
├── README.md
│
├── packer/
│   ├── main.pkr.hcl
│   └── ...
│
├── ansible/
│   └── playbook.yaml
│
└── terraform/
    ├── main.tf
    ├── variables.tf
    ├── outputs.tf
    ├── .terraform.lock.hcl
    └── ...
```

### Important generated files that should not normally be committed

The Terraform working directory can contain:

```text
terraform/.terraform/
terraform/terraform.tfstate
terraform/terraform.tfstate.backup
```

The `.terraform/` directory should normally be ignored.

Because this project uses an S3 backend, Terraform state is stored remotely rather than relying on the local state file.

Do **not** commit secrets, private SSH keys, AWS credentials, or Jenkins credentials.

---

# 3. Prerequisites

The Jenkins server requires:

- Java
- Jenkins
- Packer
- Terraform
- Ansible
- AWS CLI
- Git
- SSH

The Jenkins EC2 instance used in this project is Ubuntu.

Versions used during the project included:

```text
Packer     1.16.0
Terraform  1.15.8
Ansible    2.20.1
Java       21
```

The developer workstation may use a different Terraform version as long as the configuration remains compatible.

Verify:

```bash
packer version
terraform version
ansible --version
aws --version
java -version
```

---

# 4. AWS IAM Design

The Jenkins EC2 instance uses an IAM instance profile/role rather than storing AWS access keys on the server.

The role used in this project is:

```text
ovia-jenkins-packer-terraform
```

Verify the active identity:

```bash
aws sts get-caller-identity
```

Expected pattern:

```text
arn:aws:sts::<ACCOUNT_ID>:assumed-role/ovia-jenkins-packer-terraform/<INSTANCE_ID>
```

This is preferable to placing long-lived AWS access keys on the Jenkins server.

## Required permission categories

The Jenkins role needs permissions for:

### Packer

Packer requires permissions to:

- launch temporary EC2 instances
- create temporary key pairs
- create/delete temporary security groups
- stop/terminate temporary instances
- create AMIs
- describe EC2 resources

### Terraform S3 backend

The role needs access to the Terraform state bucket:

```text
ovia-packer-terraform-state-<ACCOUNT_ID>
```

Typical permissions include:

```text
s3:ListBucket
s3:GetObject
s3:PutObject
s3:DeleteObject
```

### Terraform Launch Templates

Required permissions include actions such as:

```text
ec2:CreateLaunchTemplate
ec2:CreateLaunchTemplateVersion
ec2:DescribeLaunchTemplates
ec2:DescribeLaunchTemplateVersions
ec2:ModifyLaunchTemplate
ec2:DeleteLaunchTemplate
```

### Terraform Auto Scaling

Required permissions include actions such as:

```text
autoscaling:DescribeAutoScalingGroups
autoscaling:DescribeAutoScalingInstances
autoscaling:DescribeScalingActivities
autoscaling:DescribeTags
autoscaling:CreateAutoScalingGroup
autoscaling:UpdateAutoScalingGroup
autoscaling:DeleteAutoScalingGroup
autoscaling:StartInstanceRefresh
autoscaling:DescribeInstanceRefreshes
```

Use least privilege in a real production environment. During initial project setup, missing permissions were identified from AWS `AccessDenied` errors and then added to the Jenkins role.

---

# 5. GitHub Access from Jenkins

Jenkins uses SSH authentication to access the GitHub repository.

The private key is stored on the Jenkins server, for example:

```text
/var/lib/jenkins/.ssh/github_jenkins
```

The private key must never be committed to GitHub.

Test the connection as the Jenkins user:

```bash
sudo -u jenkins ssh -i /var/lib/jenkins/.ssh/github_jenkins \
  -T git@github.com
```

A successful authentication looks similar to:

```text
Hi <github-user>! You've successfully authenticated,
but GitHub does not provide shell access.
```

GitHub's host key is stored in the Jenkins user's:

```text
/var/lib/jenkins/.ssh/known_hosts
```

---

# 6. Packer

## Purpose

Packer creates an immutable AWS AMI.

The Packer process is:

```text
Base Ubuntu AMI
       |
       v
Launch temporary EC2
       |
       v
SSH into EC2
       |
       v
Run provisioner
       |
       v
Stop EC2
       |
       v
Create AMI
       |
       v
Terminate temporary EC2
```

The important distinction is that **Packer is responsible for establishing the SSH connection used by its provisioner**.

When the Ansible provisioner is used:

```text
Packer
   |
   | SSH connection
   v
Temporary EC2
   |
   | Ansible commands
   v
Configured machine
```

Ansible itself uses SSH to communicate with the target, but Packer's Ansible provisioner controls how Ansible is invoked and supplies the connection details for the Packer build.

## Initialize Packer plugins

The Ansible provisioner is a Packer plugin.

Run:

```bash
cd packer
packer init .
```

Then:

```bash
packer fmt .
packer validate .
```

Expected:

```text
The configuration is valid.
```

## Build the AMI manually

```bash
packer build .
```

At the end, Packer reports an AMI such as:

```text
Builds finished. The artifacts of successful builds are:

amazon-ebs.ubuntu: AMIs were created:
us-east-1: ami-xxxxxxxxxxxxxxxxx
```

That AMI ID becomes the input to Terraform.

---

# 7. Ansible

Ansible configures the temporary EC2 created by Packer.

Example responsibilities in this project include:

```text
Update apt package cache
Install required packages
Install/verify Git
Install/verify curl
```

Run manually against a normal inventory when appropriate:

```bash
ansible-playbook -i <inventory> ansible/playbook.yaml
```

During the Packer build, Packer invokes the Ansible playbook automatically.

The playbook should remain relatively simple in this project. The purpose is to demonstrate the integration rather than build a large Ansible roles architecture.

---

# 8. Terraform

Terraform is responsible for the application infrastructure.

The architecture is:

```text
Packer AMI
    |
    v
Launch Template
    |
    v
Auto Scaling Group
    |
    v
EC2 instance
```

Terraform does **not** build the application AMI. Packer does that.

Terraform consumes the AMI ID produced by Packer.

---

# 9. Terraform Remote State

The project uses an S3 backend.

Example:

```hcl
terraform {
  backend "s3" {
    bucket       = "ovia-packer-terraform-state-<ACCOUNT_ID>"
    key          = "ovia-packer/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
```

Initialize:

```bash
terraform init
```

If migrating an existing local state into the backend:

```bash
terraform init -migrate-state
```

Verify the remote state:

```bash
aws s3 ls \
  s3://ovia-packer-terraform-state-<ACCOUNT_ID>/ovia-packer/
```

Expected:

```text
terraform.tfstate
```

Verify Terraform sees the managed resources:

```bash
terraform state list
```

---

# 10. Terraform Configuration

The project uses:

```hcl
data "aws_vpc" "default" {
  default = true
}
```

and discovers the default VPC subnets.

Only supported Availability Zones are selected for the `t3.micro` instance type.

The Launch Template uses:

```hcl
resource "aws_launch_template" "app" {
  name_prefix   = "ovia-packer-app-"
  image_id      = var.ami_id
  instance_type = "t3.micro"
}
```

The Auto Scaling Group is configured with:

```hcl
min_size         = 1
max_size         = 1
desired_capacity = 1
```

This means the application maintains one running instance.

---

# 11. Why an Auto Scaling Group?

Originally, Terraform directly managed:

```hcl
resource "aws_instance" "app"
```

Every time the AMI changed, Terraform could create a replacement EC2.

The project was changed to:

```text
Launch Template
       |
       v
Auto Scaling Group
```

This is better for an AMI-based deployment because the ASG manages the lifecycle of application instances.

Instead of accumulating EC2 instances:

```text
Deployment 1 → EC2 #1
Deployment 2 → EC2 #2
Deployment 3 → EC2 #3
```

the desired state is:

```text
Deployment 1 → EC2 #1
Deployment 2 → replace EC2 #1 with EC2 #2
Deployment 3 → replace EC2 #2 with EC2 #3
```

while maintaining:

```text
desired_capacity = 1
```

---

# 12. Terraform Commands

Format:

```bash
terraform fmt
```

Validate:

```bash
terraform validate
```

Plan:

```bash
terraform plan \
  -var="ami_id=ami-xxxxxxxxxxxxxxxxx"
```

Apply:

```bash
terraform apply \
  -var="ami_id=ami-xxxxxxxxxxxxxxxxx"
```

For automation:

```bash
terraform apply -auto-approve \
  -var="ami_id=ami-xxxxxxxxxxxxxxxxx"
```

Check state:

```bash
terraform state list
```

Check outputs:

```bash
terraform output
```

---

# 13. The Complete Manual Workflow

Before Jenkins automates everything, the complete workflow can be performed manually.

## Step 1 — Build the AMI

```bash
cd packer
packer init .
packer fmt .
packer validate .
packer build .
```

Record:

```text
AMI ID
```

For example:

```text
ami-05c00053eb53ebb2a
```

## Step 2 — Deploy the AMI with Terraform

```bash
cd ../terraform

terraform init

terraform plan \
  -var="ami_id=ami-05c00053eb53ebb2a"

terraform apply \
  -var="ami_id=ami-05c00053eb53ebb2a"
```

## Step 3 — Verify the ASG

```bash
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names ovia-packer-app \
  --query 'AutoScalingGroups[0].Instances[*].[InstanceId,LifecycleState,HealthStatus,AvailabilityZone]' \
  --output table
```

## Step 4 — Verify the EC2 AMI

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=ovia-packer-app" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name,Placement.AvailabilityZone,ImageId]' \
  --output table
```

---

# 14. Jenkins Pipeline

Jenkins automates the complete workflow.

The pipeline stages are conceptually:

```text
Checkout
   |
   v
Packer Init
   |
   v
Packer Validate
   |
   v
Packer Build
   |
   v
Extract AMI ID
   |
   v
Terraform Init
   |
   v
Terraform Plan
   |
   v
Manual Approval
   |
   v
Terraform Apply
   |
   v
Deployment complete
```

The Jenkinsfile extracts the AMI ID from Packer output and passes it to Terraform.

Example:

```bash
terraform plan -var=ami_id=$AMI_ID
```

and after approval:

```bash
terraform apply -auto-approve -var=ami_id=$AMI_ID
```

---

# 15. Jenkins Approval Gate

Before production deployment, Jenkins pauses:

```text
Deploy the new AMI to AWS?
Deploy or Abort
```

The deployment proceeds only after approval.

Conceptually:

```text
Packer
  |
  v
New AMI
  |
  v
Terraform Plan
  |
  v
+--------------------+
| Manual Approval     |
| Deploy or Abort     |
+---------+----------+
          |
          | Approved
          v
Terraform Apply
```

This gives the pipeline a controlled deployment gate.

---

# 16. What Happens During a Jenkins Run

A successful deployment looks like this:

### 1. Jenkins checks out GitHub

```text
GitHub
  ↓
Jenkins workspace
```

### 2. Packer creates a temporary EC2

```text
Packer
  ↓
temporary EC2
```

### 3. Packer connects using SSH

```text
Packer
  ↓ SSH
temporary EC2
```

### 4. Ansible configures the machine

```text
Ansible
  ↓
apt update
install packages
verify Git
verify curl
```

### 5. Packer creates the AMI

```text
Configured EC2
      ↓
    AMI
```

### 6. Packer cleans up

```text
Temporary EC2
      ↓
Terminated
```

Temporary Packer instances are expected to disappear.

### 7. Terraform initializes

```text
Terraform
    ↓
S3 backend
```

### 8. Terraform compares the new AMI with the current Launch Template

Example:

```text
old:
ami-06c...

new:
ami-05c...
```

Terraform detects the change.

### 9. Terraform creates a new Launch Template version

Conceptually:

```text
Launch Template
   |
   +-- Version 1 → AMI-v1
   |
   +-- Version 2 → AMI-v2
```

### 10. Terraform updates the ASG

The ASG is changed to use the new Launch Template version.

### 11. ASG replaces the old EC2

Example:

```text
OLD
i-049c227190552c412
AMI-v1
   |
   v
TERMINATED

NEW
i-06a89439c5df0f857
AMI-v2
   |
   v
RUNNING / HEALTHY
```

---

# 17. Verifying the Deployment

Check the ASG:

```bash
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names ovia-packer-app \
  --query 'AutoScalingGroups[0].Instances[*].[InstanceId,LifecycleState,HealthStatus,AvailabilityZone]' \
  --output table
```

Expected:

```text
---------------------------------------------------------------
|                  DescribeAutoScalingGroups                  |
+----------------------+------------+----------+--------------+
| i-xxxxxxxxxxxxxxxxxx | InService  | Healthy  | us-east-1d   |
+----------------------+------------+----------+--------------+
```

Check the actual EC2 AMI:

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=ovia-packer-app" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name,Placement.AvailabilityZone,ImageId]' \
  --output table
```

The running instance should show the newest AMI.

---

# 18. Understanding the EC2 Instances You See

It is normal to see several terminated instances in the EC2 console.

### Jenkins server

```text
jenkins-env
```

This remains running.

### Current application instance

```text
ovia-packer-app
```

This is managed by the Auto Scaling Group and should normally have one running instance.

### Old application instances

```text
ovia-packer-app
```

Older instances become:

```text
Terminated
```

### Packer temporary instances

Instances with names/keys similar to:

```text
packer_*
```

are temporary build machines.

They are expected to be terminated after the AMI is created.

---

# 19. Troubleshooting

## Packer says Ansible provisioner is unknown

Run:

```bash
packer init .
```

The Ansible provisioner is provided by the Packer Ansible plugin.

Then:

```bash
packer validate .
```

---

## Ansible fails during Gathering Facts

Verify:

- EC2 is reachable
- SSH is working
- the Ubuntu username is correct
- the Packer SSH configuration is correct
- the temporary security group permits SSH

Packer must first establish connectivity to the temporary instance.

---

## Jenkins waits for an executor

Check Jenkins node availability and disk monitoring.

This project encountered a Jenkins `/tmp` disk-threshold issue because `/tmp` was a `tmpfs`.

Useful commands:

```bash
df -h /tmp
du -sh /tmp
df -h /
```

Jenkins disk monitoring thresholds should be configured sensibly for the available resources.

---

## Terraform gets S3 403

Example:

```text
Error refreshing state:
S3 HeadObject ... 403 Forbidden
```

Check:

```bash
sudo -u jenkins aws sts get-caller-identity
```

Then verify the Jenkins role has S3 permissions for the Terraform state bucket.

---

## Terraform gets Auto Scaling 403

Example:

```text
autoscaling:DescribeAutoScalingGroups
```

Add the required Auto Scaling permissions to the Jenkins IAM role.

---

## Terraform gets Launch Template 403

Example:

```text
ec2:CreateLaunchTemplateVersion
```

Add the required Launch Template permissions to the Jenkins IAM role.

---

## ASG reports an unsupported Availability Zone

The project previously encountered:

```text
t3.micro is not supported in us-east-1e
```

The Terraform configuration therefore limits the discovered subnets to supported Availability Zones:

```text
us-east-1a
us-east-1b
us-east-1c
us-east-1d
us-east-1f
```

---

# 20. Why the Pipeline Does Not Create Endless EC2 Instances

This is one of the most important design decisions in the project.

The pipeline does **not** simply run:

```text
terraform apply
→ create another aws_instance
```

Instead:

```text
Packer creates AMI
        ↓
Terraform updates Launch Template
        ↓
Terraform updates ASG
        ↓
ASG maintains desired capacity
        ↓
Old instance is replaced
        ↓
New instance runs new AMI
```

The ASG is configured:

```text
Min = 1
Desired = 1
Max = 1
```

Therefore, after a successful deployment, the target state is one running application instance.

---

# 21. Immutable Infrastructure Concept

The project demonstrates an immutable infrastructure pattern.

Instead of SSH-ing into the production EC2 and changing packages manually:

```text
Old server
   ↓
SSH
   ↓
Install/change software
```

we create a new image:

```text
Base AMI
   ↓
Packer
   ↓
Ansible
   ↓
New immutable AMI
   ↓
New EC2
```

The old server is replaced.

This improves consistency and makes deployments repeatable.

---

# 22. End-to-End Deployment Example

Suppose the currently deployed AMI is:

```text
ami-06c...
```

A developer changes the machine configuration.

Jenkins starts.

### Packer

```text
Base AMI
   ↓
Temporary EC2
   ↓
Ansible
   ↓
Configured EC2
   ↓
ami-05c00053eb53ebb2a
```

### Terraform

```text
Current:
AMI-v1

Desired:
AMI-v2
```

Terraform creates a new Launch Template version.

### ASG

```text
Old:
i-049c227190552c412
AMI-v1
```

is replaced by:

```text
New:
i-06a89439c5df0f857
AMI-v2
```

The final state is:

```text
ASG
 |
 +-- Desired: 1
 |
 +-- Running:
       i-06a89439c5df0f857
       AMI: ami-05c00053eb53ebb2a
       State: InService
       Health: Healthy
```

---

# 23. Git Workflow

Check the repository:

```bash
git status
```

Review changes:

```bash
git diff
```

Stage:

```bash
git add .
```

Commit:

```bash
git commit -m "Implement Packer Ansible Terraform Jenkins deployment"
```

Push:

```bash
git push origin main
```

Do not commit:

```text
*.pem
*.key
credentials
AWS access keys
Jenkins secrets
terraform.tfstate
terraform.tfstate.backup
.terraform/
```

The S3 backend is the source of truth for Terraform state.

---

# 24. Production Improvements

This project is a learning/interview-ready implementation. A production implementation could add:

- Private Jenkins subnet
- Private application subnets
- NAT Gateway/VPC endpoints
- Application Load Balancer
- HTTPS/TLS
- Route 53
- Multiple application instances
- Auto Scaling policies
- CloudWatch
- Prometheus/Grafana
- Centralized logging
- Security scanning
- Trivy
- SonarQube
- Dependency scanning
- Secrets Manager
- Parameter Store
- IAM least privilege
- Multi-AZ deployment
- Automated rollback
- Blue/green deployment
- Canary deployment
- AMI cleanup/lifecycle policies
- Terraform plan artifacts
- Automated tests
- GitHub pull-request checks

---

# 25. Future GitHub Actions Implementation

The next phase of this project will reproduce the CI/CD workflow using GitHub Actions.

The target architecture will be:

```text
GitHub
   |
   v
GitHub Actions
   |
   +----------------------+
   |                      |
   v                      v
 Packer               Terraform
   |                      |
   v                      v
Ansible                AWS
   |                      |
   v                      v
  AMI                Launch Template
                          |
                          v
                         ASG
                          |
                          v
                    Application EC2
```

The purpose is to demonstrate that the same infrastructure workflow can be orchestrated using either:

```text
Jenkins
```

or:

```text
GitHub Actions
```

while keeping Packer, Ansible and Terraform as the infrastructure/build components.

---

# 26. Interview Explanation

If asked to explain this project in an interview:

> "I built an AWS AMI-based deployment pipeline using Jenkins, Packer, Ansible and Terraform. Jenkins checks out the repository and starts a Packer build. Packer launches a temporary EC2 instance and uses its SSH communicator to provision the machine with Ansible. Once provisioning succeeds, Packer creates an immutable AMI and cleans up the temporary instance. Jenkins captures the AMI ID and passes it to Terraform. Terraform stores its state remotely in S3 and manages an EC2 Launch Template and Auto Scaling Group. Terraform creates a new Launch Template version pointing to the new AMI and updates the Auto Scaling Group. The ASG then replaces the old application instance with an instance launched from the new AMI. I also added a manual approval gate between Terraform plan and apply so deployment to AWS is controlled."

A shorter version:

```text
Jenkins orchestrates.
Packer builds the immutable AMI.
Ansible configures the image.
Terraform deploys the AMI.
S3 stores Terraform state.
The Launch Template references the AMI.
The ASG manages the EC2 lifecycle.
```

---

# 27. Final Architecture

The completed Jenkins-based implementation is:

```text
                           GITHUB
                              |
                              v
                         +---------+
                         | Jenkins |
                         +----+----+
                              |
                 +------------+------------+
                 |                         |
                 v                         v
             PACKER                    TERRAFORM
                 |                         |
                 v                         v
         Temporary EC2                 S3 State
                 |                         |
                 v                         |
             ANSIBLE                      |
                 |                         |
                 v                         |
          Configured Image                |
                 |                         |
                 v                         |
              AWS AMI --------------------+
                                           |
                                           v
                                  Launch Template
                                           |
                                           v
                                  Auto Scaling Group
                                           |
                                           v
                                    Application EC2
                                           |
                                           v
                                     InService
                                      Healthy
```

## Result

The project demonstrates:

- Infrastructure as Code
- Immutable AMIs
- Configuration management
- CI/CD automation
- Jenkins pipelines
- AWS IAM roles
- Terraform remote state
- Launch Templates
- Auto Scaling Groups
- Controlled deployments
- AMI-based instance replacement
- GitHub integration
- AWS automation without long-lived AWS access keys on Jenkins
