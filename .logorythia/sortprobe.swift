import Foundation
struct User { var name: String; var age: Int }
let d1 = SortDescriptor<User>(\User.age)
let d2 = SortDescriptor<User>(\User.name, order: .reverse)
for d in [d1, d2] {
    print("TYPE", String(describing: type(of: d)))
    let mirror = Mirror(reflecting: d)
    for child in mirror.children {
        print("LABEL", String(describing: child.label), "TYPE", String(describing: type(of: child.value)), "VALUE", child.value)
        let inner = Mirror(reflecting: child.value)
        for grand in inner.children {
            print("  INNER", String(describing: grand.label), "TYPE", String(describing: type(of: grand.value)), "VALUE", grand.value)
            let deep = Mirror(reflecting: grand.value)
            for g2 in deep.children {
                print("    DEEP", String(describing: g2.label), "TYPE", String(describing: type(of: g2.value)), "VALUE", g2.value)
            }
        }
    }
}
