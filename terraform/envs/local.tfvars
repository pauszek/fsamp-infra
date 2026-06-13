
environment         = "local"
aws_region          = "us-west-2"
project_name        = "fsamp"
enable_nat_gateway  = false
use_fips_endpoint   = false
localstack_endpoint = "http://localhost:4566"

# LocalStack Pro is the primary infrastructure: the same Terraform modules
# provision the local environment (make local-all). The edge stack
# (ECS/ALB/API Gateway) and the container Lambdas are opt-in because they
# need images pushed to the local ECR first.
local_enable_core_stack = true
local_enable_edge_stack = false
local_enable_lambdas    = false
local_enable_audit      = true

tags = {
  Team = "development"
}
