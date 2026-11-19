import Foundation
import CoreGraphics


let retina = ScreenSync(bounds: CGRect(x: 0, y: 0, width: 1512, height: 982))
precondition(retina?.command == "screen 1512 982")
precondition(retina?.reply == "OK screen 1512 982")
let other = ScreenSync(bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440))
precondition(other?.command == "screen 2560 1440")
precondition(ScreenSync(bounds: .zero) == nil)
precondition(ScreenSync(bounds: CGRect(x: 0, y: 0, width: 65536, height: 1080)) == nil)
print("PASS: Mac coordinate dimensions and firmware sync format")
