# Aurora PostgreSQL Serverless v2 con RDS Data API: las Lambda consultan por HTTPS con IAM,
# sin VPC, sin NAT Gateway y sin RDS Proxy. Escritor y lector en zonas distintas (RNF-04).
# Escala a 0 ACU cuando no hay uso: sin costo de cómputo en la madrugada (solo almacenamiento).

variable "prefix" {
  type = string
}

variable "subnet_ids" {
  description = "Subredes privadas en al menos dos zonas de disponibilidad"
  type        = list(string)
}

variable "vpc_id" {
  type = string
}

variable "min_acu" {
  description = "0 = se pausa sola cuando no hay conexiones"
  type        = number
  default     = 0
}

variable "max_acu" {
  type    = number
  default = 4
}

variable "seconds_until_auto_pause" {
  description = "Tiempo sin uso antes de pausarse. 3600 = no se duerme en horario de clases"
  type        = number
  default     = 3600
}

variable "with_reader" {
  description = "Crea el lector en otra zona (RNF-04). En dev se puede apagar para ahorrar"
  type        = bool
  default     = true
}

variable "deletion_protection" {
  description = "true solo en prod: impide borrar la base por error"
  type        = bool
  default     = false
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.prefix}-db"
  subnet_ids = var.subnet_ids
}

# Sin reglas de entrada: nadie se conecta por red; solo se usa la Data API
resource "aws_security_group" "db" {
  name_prefix = "${var.prefix}-db-"
  description = "Aurora: sin reglas de entrada, solo se usa por la Data API"
  vpc_id      = var.vpc_id

  # Cambiar la descripción crea un grupo nuevo: primero el nuevo, después se borra el viejo
  lifecycle {
    create_before_destroy = true
  }
}

# Logs de Postgres en CloudWatch (en el diagrama: logs y métricas de Aurora)
resource "aws_cloudwatch_log_group" "postgresql" {
  #checkov:skip=CKV_AWS_158:Cifrado con la llave de CloudWatch; una llave propia cuesta 1 USD al mes.
  name              = "/aws/rds/cluster/${var.prefix}-db/postgresql"
  retention_in_days = 365
}

resource "aws_rds_cluster" "this" {
  #checkov:skip=CKV_AWS_327:Cifrado con la llave de RDS (storage_encrypted); una llave propia cuesta 1 USD al mes.
  #checkov:skip=CKV_AWS_139:La protección contra borrado se activa con is_prod; dev se tiene que poder destruir para no pagar.
  #checkov:skip=CKV_AWS_162:Nadie se conecta a la base por red: las Lambdas usan la Data API con IAM y el secreto de Secrets Manager.
  #checkov:skip=CKV2_AWS_27:Registrar cada consulta guardaría en los logs el texto de las notas de los usuarios.
  #checkov:skip=CKV2_AWS_8:Sí tiene plan de AWS Backup (módulo backup); Checkov no sigue el ARN que entra por variable.
  cluster_identifier              = "${var.prefix}-db"
  engine                          = "aurora-postgresql"
  engine_mode                     = "provisioned"
  engine_version                  = "16.15"
  database_name                   = "streamnote"
  master_username                 = "streamnote"
  manage_master_user_password     = true # el secreto queda en Secrets Manager
  enable_http_endpoint            = true # RDS Data API
  db_subnet_group_name            = aws_db_subnet_group.this.name
  vpc_security_group_ids          = [aws_security_group.db.id]
  storage_encrypted               = true
  backup_retention_period         = var.deletion_protection ? 35 : 1
  deletion_protection             = var.deletion_protection
  skip_final_snapshot             = !var.deletion_protection # en dev/qa se puede destruir sin snapshot
  final_snapshot_identifier       = var.deletion_protection ? "${var.prefix}-db-final" : null
  copy_tags_to_snapshot           = true
  enabled_cloudwatch_logs_exports = ["postgresql"]
  depends_on                      = [aws_cloudwatch_log_group.postgresql]

  serverlessv2_scaling_configuration {
    min_capacity             = var.min_acu
    max_capacity             = var.max_acu
    seconds_until_auto_pause = var.min_acu == 0 ? var.seconds_until_auto_pause : null
  }
}

resource "aws_rds_cluster_instance" "this" {
  #checkov:skip=CKV_AWS_353:Performance Insights no está en el diagrama; los logs de Postgres ya van a CloudWatch.
  #checkov:skip=CKV_AWS_118:El monitoreo mejorado necesita otro rol y cobra por los logs; con las métricas de CloudWatch alcanza.
  for_each                   = var.with_reader ? { writer = 0, reader = 1 } : { writer = 0 }
  identifier                 = "${var.prefix}-db-${each.key}"
  cluster_identifier         = aws_rds_cluster.this.id
  instance_class             = "db.serverless"
  engine                     = aws_rds_cluster.this.engine
  engine_version             = aws_rds_cluster.this.engine_version
  promotion_tier             = each.value
  auto_minor_version_upgrade = true
}

output "cluster_arn" {
  value = aws_rds_cluster.this.arn
}

output "secret_arn" {
  value = aws_rds_cluster.this.master_user_secret[0].secret_arn
}
