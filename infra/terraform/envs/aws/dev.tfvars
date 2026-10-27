# Desarrollo: se despliega con cada merge a develop.
stage          = "dev"
is_prod        = false
db_with_reader = false # una sola instancia: dev no necesita tolerar la caída de una zona

# TEMPORAL: login de desarrollo (sin contraseña) hasta que la web tenga el login con Cognito.
# Cualquiera con la URL puede entrar con cualquier correo. Quitar esta línea cuando llegue el PR del login.
auth_mode = "local"
