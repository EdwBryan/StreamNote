# Producción: se despliega con cada merge a main (requiere aprobación en el environment "prod").
stage          = "prod"
is_prod        = true
db_with_reader = true # escritor y lector en zonas distintas (RNF-04)
auth_mode      = "cognito"
