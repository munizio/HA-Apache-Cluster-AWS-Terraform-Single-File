# ------------------------------------------------------------ 
# Define File Variables
# ------------------------------------------------------------ 

variable "project_name" {
  default = "onica"
}

variable "aws_credentials_file" {
  default = "~/.aws/credentials"
}

variable "region" {
  default = "us-west-2"
}

variable "availability_zone" {
  default = "us-west-2a"
}

variable "server_port" {
  default = "80"
}

variable "vpc_subnet_cidr" {
  default = "10.13.1.0/24"
}

variable "private_subnet_cidr" {
  default = "10.13.1.192/26"
}

variable "public_subnet_cidr" {
  default = "10.13.1.0/28"
}

# ------------------------------------------------------------ 
# Define Provider and Pre-Req Information
# ------------------------------------------------------------ 

provider "aws" {
  region                  = "${var.region}"
  shared_credentials_file = "${var.aws_credentials_file}"
}

# ------------------------------------------------------------ 
# Create VPC Network and Associated Routes
# ------------------------------------------------------------ 

resource "aws_vpc" "default" {
  cidr_block = "${var.vpc_subnet_cidr}"
}

resource "aws_internet_gateway" "public" {
  vpc_id = "${aws_vpc.default.id}"
}

resource "aws_route_table" "public" {
  vpc_id = "${aws_vpc.default.id}"
}

resource "aws_route" "public" {
  route_table_id         = "${aws_route_table.public.id}"
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = "${aws_internet_gateway.public.id}"
}

resource "aws_route_table" "private" {
  vpc_id = "${aws_vpc.default.id}"
}

resource "aws_route" "private" {
	route_table_id  = "${aws_route_table.private.id}"
	destination_cidr_block = "0.0.0.0/0"
	nat_gateway_id = "${aws_nat_gateway.private.id}"
}

resource "aws_eip" "nat" {
  vpc         = true
  depends_on  = ["aws_internet_gateway.public"]
}

resource "aws_nat_gateway" "private" {
  allocation_id = "${aws_eip.nat.id}"
  subnet_id     = "${aws_subnet.public.id}"
  depends_on    = ["aws_internet_gateway.public"]
}

resource "aws_subnet" "public" {
  vpc_id                  = "${aws_vpc.default.id}"
  cidr_block              = "${var.public_subnet_cidr}"
  availability_zone       = "${var.availability_zone}" 
  map_public_ip_on_launch = true
}

resource "aws_subnet" "private" {
  vpc_id                  = "${aws_vpc.default.id}"
  cidr_block              = "${var.private_subnet_cidr}"
  availability_zone       = "${var.availability_zone}"
}

resource "aws_route_table_association" "public" {
    subnet_id = "${aws_subnet.public.id}"
    route_table_id = "${aws_route_table.public.id}"
}

resource "aws_route_table_association" "private" {
    subnet_id = "${aws_subnet.private.id}"
    route_table_id = "${aws_route_table.private.id}"
}

# ------------------------------------------------------------ 
# Define Security Groups and Rules
# ------------------------------------------------------------ 

resource "aws_security_group" "public" {
  name    = "${var.project_name}-public-asg"
  vpc_id  = "${aws_vpc.default.id}"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
   from_port    = 0
   to_port      = 0
   protocol     = "-1"
   cidr_blocks  = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "private" {
  name    = "${var.project_name}-private-asg"
  vpc_id  = "${aws_vpc.default.id}"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["${aws_subnet.public.cidr_block}"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ------------------------------------------------------------ 
# Create ELB
# ------------------------------------------------------------ 

resource "aws_elb" "main" {
  name = "${var.project_name}-elb"

  subnets         = ["${aws_subnet.public.id}"]
  security_groups = ["${aws_security_group.public.id}"]

  health_check {
    healthy_threshold = 2
    unhealthy_threshold = 2
    timeout = 3
    interval = 30
    target = "HTTP:${var.server_port}/"
  }

  listener {
    instance_port     = 80
    instance_protocol = "http"  
    lb_port           = 80
    lb_protocol       = "http"
  }
}

# ------------------------------------------------------------ 
# Create Auto-Scale Group and Launch Configuration
# ------------------------------------------------------------ 

resource "aws_launch_configuration" "web" {
  name            = "${var.project_name}-web-cfg"
  image_id        = "ami-db710fa3"
  instance_type   = "t2.nano"
  security_groups = ["${aws_security_group.private.id}"]

  user_data = <<-EOF
              #!/bin/bash
              sudo apt-get update
              sudo apt-get install -y apache2
              sudo systemctl start apache2

              sudo mkdir -p /var/www/www.test.com/html
              sudo mkdir -p /var/www/www2.test.com/html

              sudo cat <<- END > /etc/apache2/sites-available/www.test.com.conf
                <VirtualHost *:80>
                  ServerName www.test.com
                  ServerAlias www.test.com
                  DocumentRoot /var/www/www.test.com/html/
                </VirtualHost>
              END

              sudo cat <<- END > /etc/apache2/sites-available/www2.test.com.conf
                <VirtualHost *:80>
                  ServerName www2.test.com
                  ServerAlias www2.test.com
                  DocumentRoot /var/www/www2.test.com/html/
                </VirtualHost>
              END

              sudo cat <<- END >> /etc/hosts
                127.0.0.1 www.test.com www2.test.com
              END

              sudo echo "hello test" > /var/www/www.test.com/html/index.html
              sudo echo "hello test2" > /var/www/www2.test.com/html/index.html

              sudo ln -s /etc/apache2/sites-available/www.test.com.conf /etc/apache2/sites-enabled/www.test.com.conf
              sudo ln -s /etc/apache2/sites-available/www2.test.com.conf /etc/apache2/sites-enabled/www2.test.com.conf

              sudo systemctl restart apache2
              sudo systemctl enable apache2
              EOF

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "web" {
  name                  = "${var.project_name}-web-asg"
  launch_configuration  = "${aws_launch_configuration.web.id}"
  vpc_zone_identifier   = ["${aws_subnet.private.id}"]

  min_size = 2
  max_size = 2

  load_balancers    = ["${aws_elb.main.name}"]

  tag {
    key                 = "Name"
    value               = "${var.project_name}-web-asg"
    propagate_at_launch = true
  }
}

# ------------------------------------------------------------ 
# Declare Outputs
# ------------------------------------------------------------ 

output "elb_dns_name" {
  value = "${aws_elb.main.dns_name}"
}
