# Bucket de grabaciones con la política de retención acordada:
# - estado=provisional  → se borra a los N días si nadie la conserva
# - estado=conservada   → nunca se borra; baja a Glacier Instant Retrieval (día 30) y a Deep Archive (día 180)
# La API cambia la etiqueta con PutObjectTagging cuando alguien pulsa "Conservar".

variable "prefix" {
  type = string
}

variable "provisional_days" {
  type    = number
  default = 3
}

variable "force_destroy" {
  description = "true solo en local: permite borrar el bucket con objetos dentro"
  type        = bool
  default     = false
}

resource "aws_s3_bucket" "recordings" {
  #checkov:skip=CKV_AWS_145:Cifrado SSE-S3 (AES-256). KMS agrega costo por solicitud y no cambia quién puede leerlo.
  #checkov:skip=CKV_AWS_18:Un bucket de logs de acceso no está en el diagrama; el acceso a los objetos ya pasa por CloudFront o por URLs firmadas.
  #checkov:skip=CKV2_AWS_62:Nada reacciona a la subida de un archivo, no hace falta notificar eventos.
  #checkov:skip=CKV_AWS_144:Una sola región por diseño (diagrama y documento); replicar a otra región duplica el costo.
  bucket        = "${var.prefix}-recordings"
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_public_access_block" "recordings" {
  bucket                  = aws_s3_bucket.recordings.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "recordings" {
  bucket = aws_s3_bucket.recordings.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Si alguien borra o pisa una grabación, la versión anterior se puede recuperar (RNF-08)
resource "aws_s3_bucket_versioning" "recordings" {
  bucket = aws_s3_bucket.recordings.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "recordings" {
  bucket     = aws_s3_bucket.recordings.id
  depends_on = [aws_s3_bucket_versioning.recordings]

  rule {
    id     = "limpieza"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  rule {
    id     = "borrar-provisionales"
    status = "Enabled"
    filter {
      tag {
        key   = "estado"
        value = "provisional"
      }
    }
    expiration {
      days = var.provisional_days
    }
  }

  rule {
    id     = "degradar-conservadas"
    status = "Enabled"
    filter {
      tag {
        key   = "estado"
        value = "conservada"
      }
    }
    transition {
      days          = 30
      storage_class = "GLACIER_IR"
    }
    transition {
      days          = 180
      storage_class = "DEEP_ARCHIVE"
    }
  }
}

output "bucket_name" {
  value = aws_s3_bucket.recordings.bucket
}

output "bucket_arn" {
  value = aws_s3_bucket.recordings.arn
}
