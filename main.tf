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
  version = "~> 9.0" # Upgrading to match the modern ASG module

  name    = "blog-alb"
  vpc_id  = module.blog_vpc.vpc_id
  subnets = module.blog_vpc.public_subnets
  
  # Ensure the ALB's own security group allows traffic from your IP
  security_group_ingress_rules = {
    all_http = {
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      description = "HTTP web traffic"
      cidr_ipv4   = "213.41.3.224/28"
    }
  }
  
  security_group_egress_rules = {
    all_traffic = {
      description      = "Allow all egress traffic"
      protocol         = "-1"
      from_port        = 0
      to_port          = 0
      cidr_ipv4        = "0.0.0.0/0"
    }
  }

  # Updated Map Syntax for Target Groups
  target_groups = {
    blog-tg = {
      backend_protocol                  = "HTTP"
      backend_port                      = 8080
      target_type                       = "instance"
      deregistration_delay              = 10
      load_balancing_algorithm_type     = "round_robin"
      
      health_check = {
        enabled             = true
        interval            = 30
        path                = "/"
        port                = "traffic-port"
        healthy_threshold   = 3
        unhealthy_threshold = 3
        timeout             = 5
        protocol            = "HTTP"
        matcher             = "200-399"
      }
    }
  }

  listeners = {
    http = {
      port     = 80
      protocol = "HTTP"
      forward = {
        target_group_key = "blog-tg"
      }
    }
  }

  tags = {
    Environment = "dev"
  }
}

module "blog_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "5.3.1"


  vpc_id = module.blog_vpc.vpc_id
  name  = "blog"
  ingress_rules = ["http-80-tcp", "https-443-tcp"]
  ingress_cidr_blocks = ["213.41.3.224/28"]

  egress_rules = ["all-all"]
  egress_cidr_blocks = ["0.0.0.0/0"]
  
}

