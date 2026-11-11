# Red mínima para Aurora: una VPC con dos subredes privadas en zonas distintas (RNF-04).
# No hay Internet Gateway ni NAT Gateway: nada entra ni sale a Internet por esta red.
# Las Lambda no viven aquí; hablan con Aurora por la RDS Data API (HTTPS + IAM).
# Una VPC y sus subredes no tienen costo.

variable "prefix" {
  type = string
}

variable "cidr" {
  type    = string
  default = "10.20.0.0/16"
}

# Las zonas A y B del diagrama, fijas: si AWS agrega otra zona, la red no cambia sola
data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "zone-name"
    values = ["us-east-1a", "us-east-1b"]
  }
}

resource "aws_vpc" "this" {
  #checkov:skip=CKV2_AWS_11:En esta VPC no hay tráfico que registrar: las Lambdas están fuera y hablan con Aurora por la Data API (HTTPS).
  #checkov:skip=CKV2_AWS_12:Nadie usa el grupo por defecto; Aurora tiene su propio grupo sin reglas de entrada.
  cidr_block           = var.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.prefix}-vpc" }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.cidr, 8, count.index) # 10.20.0.0/24 y 10.20.1.0/24
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = { Name = "${var.prefix}-privada-${count.index == 0 ? "a" : "b"}" }
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}
