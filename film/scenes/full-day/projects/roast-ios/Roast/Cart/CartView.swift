import SwiftUI

struct CartView: View {
    @ObservedObject var cart: Cart

    var body: some View {
        List {
            ForEach(cart.lines) { line in
                HStack { Text(line.name); Spacer(); Text(line.price, format: .currency(code: "USD")) }
            }
            HStack { Text("Total").bold(); Spacer(); Text(cart.total, format: .currency(code: "USD")).bold() }
        }
        .navigationTitle("Cart")
    }
}
