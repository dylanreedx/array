resource "postgres_database" "orders" {
  name  = "roast_orders"
  owner = "roast"
}
