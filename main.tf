provider "aws" {
  region = "${var.region}"
}

#
# Container Instance IAM resources
#
data "aws_iam_policy_document" "container_instance_ec2_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "container_instance_ec2" {
  name               = "${var.environment}ContainerInstanceProfile"
  assume_role_policy = "${data.aws_iam_policy_document.container_instance_ec2_assume_role.json}"
}

resource "aws_iam_role_policy_attachment" "ec2_service_role" {
  role       = "${aws_iam_role.container_instance_ec2.name}"
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_instance_profile" "container_instance" {
  name = "${aws_iam_role.container_instance_ec2.name}"
  role = "${aws_iam_role.container_instance_ec2.name}"
}

#
# ECS Service IAM permissions
#

data "aws_iam_policy_document" "ecs_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ecs.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "ecs_service_role" {
  name               = "ecs${title(var.environment)}ServiceRole"
  assume_role_policy = "${data.aws_iam_policy_document.ecs_assume_role.json}"
}

resource "aws_iam_role_policy_attachment" "ecs_service_role" {
  role       = "${aws_iam_role.ecs_service_role.name}"
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceRole"
}

data "aws_iam_policy_document" "ecs_autoscale_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["application-autoscaling.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

#
# Security group resources
#
resource "aws_security_group" "container_instance" {
  vpc_id = "${var.vpc_id}"

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = [
      "0.0.0.0/0"]
  }

  tags {
    Name        = "sgContainerInstance"
    Project     = "${var.project}"
    Environment = "${var.environment}"
  }
}

#
# AutoScaling resources
#
data "template_file" "container_instance_base_cloud_config" {
  template = "${file("${path.module}/cloud-config/base-container-instance.yml.tpl")}"

  vars {
    ecs_cluster_name = "${aws_ecs_cluster.container_instance.name}"
  }
}

data "template_cloudinit_config" "container_instance_cloud_config" {
  gzip          = false
  base64_encode = false

  part {
    content_type = "text/cloud-config"
    content      = "${data.template_file.container_instance_base_cloud_config.rendered}"
  }

  part {
    content_type = "${var.cloud_config_content_type}"
    content      = "${var.cloud_config_content}"
  }
}

data "aws_ami" "ecs_ami" {
  count       = "${var.lookup_latest_ami ? 1 : 0}"
  most_recent = true

  filter {
    name   = "name"
    values = ["amzn-ami-*-amazon-ecs-optimized"]
  }

  filter {
    name   = "owner-alias"
    values = ["${var.ami_owners}"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_ami" "user_ami" {
  count  = "${var.lookup_latest_ami ? 0 : 1}"
  owners = ["${var.ami_owners}"]

  filter {
    name   = "image-id"
    values = ["${var.ami_id}"]
  }
}

resource "aws_launch_configuration" "container_instance" {
  count = "${length(var.instance_types)}"

  lifecycle {
    create_before_destroy = true
  }

  root_block_device {
    volume_type = "${element(var.root_block_device_type, count.index)}"
    volume_size = "${element(var.root_block_device_size, count.index)}"
  }

  name_prefix          = "lc${title(var.environment)}ContainerInstance-"
  iam_instance_profile = "${aws_iam_instance_profile.container_instance.name}"

  # Using join() is a workaround for depending on conditional resources.
  # https://github.com/hashicorp/terraform/issues/2831#issuecomment-298751019
  image_id = "${var.lookup_latest_ami ? join("", data.aws_ami.ecs_ami.*.image_id) : join("", data.aws_ami.user_ami.*.image_id)}"

  instance_type   = "${element(var.instance_types, count.index)}"
  key_name        = "${var.key_name}"
  security_groups = ["${aws_security_group.container_instance.id}"]
  user_data       = "${data.template_cloudinit_config.container_instance_cloud_config.rendered}"
}

resource "aws_autoscaling_group" "container_instance" {
  count = "${length(var.instance_types)}"
  lifecycle {
    create_before_destroy = true
  }

  name                      = "asg${title(var.environment)}ContainerInstance${count.index}"
  launch_configuration      = "${element(aws_launch_configuration.container_instance.*.name, count.index)}"
  health_check_grace_period = "${var.health_check_grace_period}"
  health_check_type         = "EC2"
  desired_capacity          = "${element(var.desired_capacity, count.index)}"
  termination_policies      = ["OldestLaunchConfiguration", "Default"]
  min_size                  = "${element(var.min_size, count.index)}"
  max_size                  = "${element(var.max_size, count.index)}"
  enabled_metrics           = ["${var.enabled_metrics}"]
  vpc_zone_identifier       = ["${var.private_subnet_ids}"]

  tag {
    key                 = "Name"
    value               = "ContainerInstance"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = "${var.project}"
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = "${var.environment}"
    propagate_at_launch = true
  }
}

#
# ECS resources
#
resource "aws_ecs_cluster" "container_instance" {
  name = "ecs${title(var.environment)}Cluster"
}

#
# CloudWatch resources
#
resource "aws_autoscaling_policy" "container_instance_scale_up" {
  count = "${length(var.instance_types)}"

  name                   = "asgScalingPolicy${title(var.environment)}ClusterScaleUp${count.index}"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = "${element(var.scale_up_cooldown_seconds, count.index)}"
  autoscaling_group_name = "${element(aws_autoscaling_group.container_instance.*.name, count.index)}"
}

resource "aws_autoscaling_policy" "container_instance_scale_down" {
  count = "${length(var.instance_types)}"
  name                   = "asgScalingPolicy${title(var.environment)}ClusterScaleDown${count.index}"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = "${element(var.scale_down_cooldown_seconds, count.index)}"
  autoscaling_group_name = "${element(aws_autoscaling_group.container_instance.*.name, count.index)}"
}

resource "aws_cloudwatch_metric_alarm" "container_instance_high_cpu" {
  count = "${length(var.instance_types)}"

  alarm_name          = "alarm${title(var.environment)}ClusterCPUReservationHigh${count.index}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "${element(var.high_cpu_evaluation_periods, count.index)}"
  metric_name         = "CPUReservation"
  namespace           = "AWS/ECS"
  period              = "${element(var.high_cpu_period_seconds, count.index)}"
  statistic           = "Maximum"
  threshold           = "${element(var.high_cpu_threshold_percent, count.index)}"

  dimensions {
    ClusterName = "${aws_ecs_cluster.container_instance.name}"
  }

  alarm_description = "Scale up if CPUReservation is above N% for N duration"
  alarm_actions     = ["${element(aws_autoscaling_policy.container_instance_scale_up.*.arn, count.index)}"]
}

resource "aws_cloudwatch_metric_alarm" "container_instance_low_cpu" {
  count = "${length(var.instance_types)}"
  alarm_name          = "alarm${title(var.environment)}ClusterCPUReservationLow${count.index}"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = "${element(var.low_cpu_evaluation_periods, count.index)}"
  metric_name         = "CPUReservation"
  namespace           = "AWS/ECS"
  period              = "${element(var.low_cpu_period_seconds, count.index)}"
  statistic           = "Maximum"
  threshold           = "${element(var.low_cpu_threshold_percent, count.index)}"

  dimensions {
    ClusterName = "${aws_ecs_cluster.container_instance.name}"
  }

  alarm_description = "Scale down if the CPUReservation is below N% for N duration"
  alarm_actions     = ["${element(aws_autoscaling_policy.container_instance_scale_down.*.arn, count.index)}"]

  depends_on = ["aws_cloudwatch_metric_alarm.container_instance_high_cpu"]
}

resource "aws_cloudwatch_metric_alarm" "container_instance_high_memory" {
  count = "${length(var.instance_types)}"
  alarm_name          = "alarm${title(var.environment)}ClusterMemoryReservationHigh${count.index}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "${element(var.high_memory_evaluation_periods, count.index)}"
  metric_name         = "MemoryReservation"
  namespace           = "AWS/ECS"
  period              = "${element(var.high_memory_period_seconds, count.index)}"
  statistic           = "Maximum"
  threshold           = "${element(var.high_memory_threshold_percent, count.index)}"

  dimensions {
    ClusterName = "${aws_ecs_cluster.container_instance.name}"
  }

  alarm_description = "Scale up if the MemoryReservation is above N% for N duration"
  alarm_actions     = ["${element(aws_autoscaling_policy.container_instance_scale_up.*.arn, count.index)}"]

  depends_on = ["aws_cloudwatch_metric_alarm.container_instance_low_cpu"]
}

resource "aws_cloudwatch_metric_alarm" "container_instance_low_memory" {
  count = "${length(var.instance_types)}"
  alarm_name          = "alarm${title(var.environment)}ClusterMemoryReservationLow${count.index}"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = "${element(var.low_memory_evaluation_periods, count.index)}"
  metric_name         = "MemoryReservation"
  namespace           = "AWS/ECS"
  period              = "${element(var.low_memory_period_seconds, count.index)}"
  statistic           = "Maximum"
  threshold           = "${element(var.low_memory_threshold_percent, count.index)}"

  dimensions {
    ClusterName = "${aws_ecs_cluster.container_instance.name}"
  }

  alarm_description = "Scale down if the MemoryReservation is below N% for N duration"
  alarm_actions     = ["${element(aws_autoscaling_policy.container_instance_scale_down.*.arn, count.index)}"]

  depends_on = ["aws_cloudwatch_metric_alarm.container_instance_high_memory"]
}
