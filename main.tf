data "aws_ami" "app_ami" {
  most_recent = true

  filter {
    name   = "name"
    values = ["bitnami-tomcat-*-x86_64-hvm-ebs-nami"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["979382823631"] # Bitnami
}

data "aws_vpc" "default" {
  default = true
}

module "blog_vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "dev"
  cidr = "10.0.0.0/16"

  azs             = ["us-west-2a", "us-west-2b", "us-west-2c"]

  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  tags = {
    Terraform = "true"
    Environment = "dev"
  }
}


module "autoscaling" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "9.1.0"

  name = "blog-asg"

  # ASG Capacity settings
  min_size                  = 1
  max_size                  = 2
  desired_capacity          = 1
  wait_for_capacity_timeout = 0
  health_check_type         = "ELB"
  health_check_grace_period = 300 # Wait 5 minutes before checking health

  # Network settings
  vpc_zone_identifier = module.blog_vpc.public_subnets
  security_groups     = [module.blog_sg.security_group_id]

  # Launch Template settings
  create_launch_template = true
  image_id               = data.aws_ami.app_ami.id
  instance_type          = var.instance_type
  
  # Ensure the instance has a public IP if in a public subnet
  network_interfaces = [
    {
      delete_on_termination = true
      description           = "eth0"
      device_index          = 0
      associate_public_ip_address = true
    }
  ]

  # Traffic Source (Updated for v9.1.0 compatibility)
  traffic_source_attachments = {
      alb = {
        # Use the key 'blog-tg' defined in the ALB module above
        traffic_source_identifier = module.blog_alb.target_groups["blog-tg"].arn
        traffic_source_type       = "elbv2"
      }
  }

  tags = {
    Environment = "dev"
    Project     = "blog"
  }
}



module "blog_alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 9.0"

  name    = "blog-alb"
  vpc_id  = module.blog_vpc.vpc_id
  subnets = module.blog_vpc.public_subnets

  # --- THIS IS THE MISSING PIECE ---
  # This opens port 80 on the Load Balancer itself
  security_group_ingress_rules = {
    all_http = {
      from_port   = 80
      to_port     = 80
      ip_protocol = "tcp"
      description = "Allow HTTP from my IP"
      cidr_ipv4   = "213.41.3.224/28" 
    }
  }

  security_group_egress_rules = {
    all_traffic = {
      ip_protocol = "-1"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }
  # ---------------------------------

  target_groups = {
    blog-tg = {
      backend_protocol  = "HTTP"
      backend_port      = 8080 # Tomcat port
      target_type       = "instance"
      create_attachment = false
      health_check = {
        enabled             = true
        path                = "/"
        port                = "traffic-port"
        # Allow 200 (OK) and 302 (Redirect)
        matcher             = "200-399" 
        interval            = 30
        timeout             = 5
        healthy_threshold   = 2
        unhealthy_threshold = 2
      }
    }
  }

  listeners = {
    http = {
      port     = 80
      protocol = "HTTP"
      forward  = { target_group_key = "blog-tg" }
    }
  }
}

module "blog_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "5.3.1"

  vpc_id = module.blog_vpc.vpc_id
  name   = "blog-instance-sg"

  # IMPORTANT: Allow the ALB to reach the instances on port 8080
  ingress_with_source_security_group_id = [
    {
      from_port   = 8080
      to_port     = 8080
      protocol    = "tcp"
      description = "Allow health checks from ALB"
      source_security_group_id = module.blog_alb.security_group_id
    }
  ]

  egress_rules = ["all-all"]
}