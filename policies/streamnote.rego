# Reglas del equipo que Checkov no revisa. Se evalúan sobre el plan de Terraform en JSON:
#   terraform show -json tfplan > plan.json
#   opa eval -d policies -i plan.json "data.streamnote.deny"
# La regla 4 necesita además el costo estimado: -d costo.json (lo arma el deploy con Infracost).
package streamnote

import rego.v1

region := "us-east-1"

prefijo := sprintf("streamnote-%s", [input.variables.stage.value])

cambios contains rc if {
	some rc in input.resource_changes
	rc.mode == "managed"
	some accion in rc.change.actions
	accion in {"create", "update"}
}

# 1) Todo va en us-east-1, la única región del diagrama (también los proveedores de cada servicio)
deny contains msg if {
	some nombre, p in input.configuration.provider_config
	p.name == "aws"
	r := p.expressions.region.constant_value
	r != region
	msg := sprintf("El proveedor %s apunta a %s; el proyecto va solo en %s", [nombre, r, region])
}

# 2) Cada recurso lleva las etiquetas proyecto, entorno y servicio, para saber de quién es cada costo
deny contains msg if {
	some rc in cambios
	etiquetas := rc.change.after.tags_all
	some e in ["proyecto", "entorno", "servicio"]
	not etiquetas[e]
	msg := sprintf("%s no tiene la etiqueta %s", [rc.address, e])
}

# 3) Los nombres empiezan con streamnote-<entorno> (los grupos de logs empiezan con /aws/)
deny contains msg if {
	some rc in cambios
	some campo in ["name", "bucket", "function_name", "cluster_identifier", "identifier"]
	nombre := rc.change.after[campo]
	is_string(nombre)
	not startswith(nombre, "/aws/")
	not startswith(nombre, "arn:") # un ARN apunta a otro recurso (p. ej. la Lambda de una cola), no es un nombre nuevo
	nombre != "$default"
	not startswith(nombre, prefijo)
	msg := sprintf("%s se llama %s; debe empezar con %s", [rc.address, nombre, prefijo])
}

# 4) El costo del mes, con IGV, no pasa el límite del ambiente. El deploy pasa dos estimaciones
#    de Infracost en data.costo: "plan" (lo fijo, tal como lo aplicará Terraform) y "codigo"
#    (el mismo ambiente con su archivo de uso, que suma lo que se cobra por pedido). Se usa la mayor.
#    Sin data.costo (por ejemplo, al probar en local) la regla no aplica.
igv := 1.18

limite_mensual := {
	"dev": 10, # el presupuesto streamnote-mensual
	"qa": 10,
	"prod": 400, # la estimación de uso-prod da ~340 con IGV
}

deny contains msg if {
	entorno := input.variables.stage.value
	estimado := max([data.costo.plan, data.costo.codigo]) * igv
	estimado > limite_mensual[entorno]
	msg := sprintf("%s costaría %.2f USD al mes con IGV; el límite es %v USD", [entorno, estimado, limite_mensual[entorno]])
}
