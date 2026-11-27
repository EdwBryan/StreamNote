# El módulo usa el proveedor de AWS que le pasa el ambiente (con sus etiquetas por defecto)
terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}
