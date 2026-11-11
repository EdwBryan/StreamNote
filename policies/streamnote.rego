# Reglas del equipo que Checkov no revisa. Se evalúan sobre el plan de Terraform en JSON:
#   terraform show -json tfplan > plan.json
#   opa eval -d policies -i plan.json "data.streamnote.deny"
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

# 1) Todo va en us-east-1, la única región del diagrama
deny contains msg if {
	r := input.configuration.provider_config.aws.expressions.region.constant_value
	r != region
	msg := sprintf("El provider apunta a %s; el proyecto va solo en %s", [r, region])
}

# 2) Cada recurso lleva las etiquetas proyecto y entorno, para saber de quién es cada costo
deny contains msg if {
	some rc in cambios
	etiquetas := rc.change.after.tags_all
	some e in ["proyecto", "entorno"]
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
	nombre != "$default"
	not startswith(nombre, prefijo)
	msg := sprintf("%s se llama %s; debe empezar con %s", [rc.address, nombre, prefijo])
}
