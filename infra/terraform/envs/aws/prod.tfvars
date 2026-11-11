# Producción: hoy no se despliega (solo dev). Si se activa, conviene un environment "prod" con aprobación.
stage          = "prod"
is_prod        = true
db_with_reader = true # escritor y lector en zonas distintas (RNF-04)
auth_mode      = "cognito"
