--- Primitive classes
-- @module primitives
-- @author nosyliam

assert(Class)

--- Creates a number object. The number class exists solely for overload declaration.
-- @function Number
-- @within Number
-- @tparam number Value
-- @treturn Number
do Number = Class('Number')
    --- Number value
    -- @field Number.value
    -- @within Number
    Number.value = 0
    function Number:construct(n)
        self.value = n
    end
    
    --- 
    -- @field Number.val
    -- @within Number
    Number:property "val" {get = (function(self) return self.value end)}
    --- 
    -- @field Number.v
    -- @within Number
    Number:property "v" {get = (function(self) return self.value end)}
    --- 
    -- @field Number.num
    -- @within Number
    Number:property "num" {get = (function(self) return self.value end)}
end

return {}