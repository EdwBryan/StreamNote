# Desarrollo: se despliega con cada merge a development.
stage                 = "dev"
is_prod               = false
db_with_reader        = false # una sola instancia: dev no necesita tolerar la caída de una zona
backup_retention_days = 7     # dev: una semana alcanza para pruebas y no traba el destroy
importar_logs_lambda  = true  # solo el primer deploy: los grupos de logs ya existen en dev (después se quita)
