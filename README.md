# RDX.lua

RDX.lua is a rapid development library by ROBLOX developers and for ROBLOX developers. Documentation, convenience, and code readability are RDX's three key
design goals. RDX allows for the rapid prototyping and development of classes and modules through a comprehensive OOP implementation and
hundreds of bug-restricant utility classes. 

## Features

* Prototype-based OOP
* Subclassing
* Function Overloading
* Field Traits (private, protected, virtual, etc)
* C#-style Properties
* More to come!

# Example

```lua
Base = Class('Base')
Base.static.apples = 10
Base.private.bananas = 7
Base.protected.oranges = 100
function Base:getBananas()
  return self.bananas
end

Derived = Class('Derived', Base)
function Derived:getOranges()
  return self.oranges
end

print(Base.apples) -- 10
print(Base:new():getBananas()) -- 7
print(Derived:new():getOranges()) -- 100
```
