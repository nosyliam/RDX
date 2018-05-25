--- Core OOP implementation
-- @module class
-- @author nosyliam
-- @set sort=true

ROBLOX_TO_CLASS = {
}
PRIMITIVE_TO_CLASS = {}
DECL_FLAGS = {
    private = 1,
    virtual = 2,
    protected = 3,
    final = 4,
    static = 5,
}

META_OPS = {
	__len       = {'len', '#'},
	__unm       = {'unary', 'minus', '--'},
	__add       = {'add', 'addition', '+'},
	__sub       = {'sub', 'subtraction', '-'},
	__mul       = {'mul', 'multiplication', '*'},
	__div       = {'div', 'division', '/'},
	__mod       = {'mod', 'modulus', '%'},
	__pow       = {'pow', 'power', 'exponent', '^'},
	__lt        = {'lt', 'less', 'lessthan', '<'},
	__eq        = {'eq', 'equal', 'equals', '='},
	__le        = {'le', '<='},
	__concat    = {'concat', 'join', '..'},
	__call      = {'call', '()', 'exec'},
	__tostring  = {'tostring', 'str'}
}

--- Create an empty class prototype with the given identifier.
-- @function Class
-- @within Class
-- @tparam string identifier Class identifier
-- @tparam {Class,...} superclasses
-- @treturn Class Class prototype
function Class(identifier, ...)
    --[[
    The tangential class variable shall never be accessed outside
    of the initial base class constructor -- it's sole purpose is for registering and
    storing functions, values, and references. The benefit of diverging the metatable
    of the class into a proxy is that any form of index will *always* be triggered and subsequently validated.
    ]]
    local Class = {id = identifier, supers = {}, decl = true, _decltraits = 0}
    local Prototype = newproxy(true)
    local Metatable = getmetatable(Prototype)
    local Overrides = {}
    
    -- Utility functions
    local function DeepCopy(orig)
        local copy
        if type(orig) == 'table' then
            copy = {}
            for key, value in next, orig, nil do
                copy[DeepCopy(key)] = DeepCopy(value)
            end
        else -- number, string, boolean, etc
            copy = orig
        end
        return copy
    end
    
    local function TableSize(tbl)
        local count = 0
        for _ in pairs(tbl) do 
            count = count + 1 
        end
        return count
    end
    
    local function FindOpFromAlias(op)
        for realop, aliases in pairs(META_OPS) do
            for _, alias in pairs(aliases) do
                if alias == op then
                    return realop
                end
            end
        end
    end

    --[[
    GenerateSignature will create a signature string with the given class, value name, and
    further arguments. Similar to C++, signatures are key to ensuring that functions with the
    same name or overloads are properly differentiated by the dispatcher.
    ]]
    local function GenerateSignature(name, ...)
        local signature = name
        for _, arg in pairs({...}) do
            if RDX_ROBLOX and type(arg) == "table" and ROBLOX_TO_CLASS[arg] then
                arg = ROBLOX_TO_CLASS[arg]
            end

            if type(arg) ~= "userdata" then
                arg = PRIMITIVE_TO_CLASS[type(arg)]
            end
            
            success, ret = pcall(arg.type, arg)
            if success then
                signature = signature .. ret
            else
                error(('Unknown userdata <%s> passed as argument to registered function <%s>'):format(tostring(arg), name))
            end
        end
        
        return signature
    end
    
    --[[
    Before any class function is called, CreateFunctionWrapper is called to create a wrapper
    any index operation that w are inside a function as to allow for the access of private and protected fields.
    ]]
    function CreateFunctionWrapper(proxy, class)
        wrapper = newproxy(true)
        wrapperMetatable = getmetatable(wrapper)
        wrapperMetatable.__index = function(_, key)
            return Metatable.__index(proxy, key, class, true)
        end
        wrapperMetatable.__newindex = function(_, key, new, classObject, traits) 
            return Metatable.__newindex(proxy, key, new, classObject, traits, true)
        end
        wrapperMetatable.__metatable = ('<protected class function wrapper metatable %s>'):format(tostring(wrapper))
        for op, _ in pairs(META_OPS) do
            wrapperMetatable[op] = function(_, ...) return Metatable[op](proxy, ...) end
        end
        
        return wrapper
    end
    
    local function CreateDeclWrapper(class, proxy, flag)
        if pcall(function() return proxy._decltraits end) then
            -- We're dealing with a trait wrapper. Instead of creating an entirely new wrapper, we may
            -- simply modify the existing traits.
            proxy._decltraits[flag] = true
            return proxy
        else
            -- A neat trick we can use to declare fields with traits is wrap our current class with
            -- a __newindex function that passes traits.
            local traits = {_decltraits = {[flag] = true}} 
            local wrapper = newproxy(true)
            local wrapperMetatable = getmetatable(Wrapper)
            wrapperMetatable.__metatable = ("<protected trait wrapper metatable %s>"):format(tostring(wrapper))
            wrapperMetatable.__index = function(_, key)
                return traits[key] or Metatable.__index(wrapper, key, class)
            end
            
            wrapperMetatable.__newindex = function(_, key, val)
                if traits[key] then traits[key] = val end
                return Metatable.__newindex(wrapper, key, val, class, traits._decltraits)
            end
            
            for op, _ in pairs(META_OPS) do
                wrapperMetatable[op] = function(...) return Metatable[op](...) end
            end
            
            return wrapper
        end
    end
    
    function Class:dispatch(proxy, name, value, class, fastFunc, ...)
        assert(Prototype ~= proxy, ("Attempt to dispatch function <%s> from prototype <%s>"):format(tostring(name), self:type()))
        assert(self:instanceOf(proxy), ("Attempt to dispatch function <%s> from unrelated class <%s>"):format(tostring(name), self:type()))
        -- If the function was called by : we need to remove the proxy provided
        -- by Lua and replace it with a function wrapper
        local args = {...}
        if args[1] == proxy then
            table.remove(args, 1)
        end
        -- We can either use the function provided by fastFunc or the function overloads.
        local match = fastFunc or value.overloads[GenerateSignature(name, unpack(args))]
        if match then
            -- Call the function and return!
            return match(CreateFunctionWrapper(proxy, class), unpack(args))
        else
            error(('Unable to dispatch function <%s> with given arguments'):format(name))
        end
    end

    
    --- Creates a property with the given field. Inspired by C#, properties are fields in a class that will 
    -- act upon accessors get and set. Properties have numerous uses, such as validating field data, processing
    -- raw data, or making a field read-only. Accessor functions are treated as class functions, but called with an
    -- environment where the property name is set to the property's current value. In addition, the set accessor is
    -- given an additional environment variable `value` which stores the value passed to the property. The initial value
    -- of the property is set to the value of `default` in the accessors table; if it does not exist, the default value is zero.
    -- @function Class:property
    -- @within Class
    -- @tparam string name Property name
    -- @tparam table accessors Accessor table
    -- @usage Person = Class('Person')
    -- Person:property "name" {
    --      set = function() name = value end;
    --      get = function() return "Mr. " .. name end;
    --      default = "";
    -- }
    -- Bob.name = "Bob"
    -- print(Bob.name) -- "Mr. Bob"
    function Class:property(name, accessors)
        -- Before anything, we need to proceed with proper assertions
        assert(accessors and type(accessors) == "table", ("Invalid accessor table passed to :property"))
        assert(self:isPrototype(), ("Attempt to declare property <%s> outside of prototype"):format(name))
        assert(not self[name], ("Attempt to declare already-existing field <%s>"):format(name))
        
        -- traits is automatically set by __index
        assert(not (traits[DECL_FLAGS.private] and traits[DECL_FLAGS.protected]), ("Private and protected declaration is not permitted"))
        
        -- We can now proceed to storing our property as normal
        self[name] = {
            ref        = accessors.default or 0,
            accessors  = accessors,
            overloads  = {},     
            class      = self.proxy or Prototype, 
            traits     = traits
        }
    end
    
    --- Creates a new function overload on the given field. For an overload to be defined, the field
    -- must not exist or have at least one overload. When an overloaded function is called, the function
    -- dispatcher will create a signature based on the arguments passed and determine the correct overload to call.
    -- Overloaded functions may not use primitive types except functions and userdatas. Overloaded functions may also not
    -- be static. The final argument of :overload must be a function.
    -- @within Class
    -- @tparam string field
    -- @tparam {Class,...,function} arguments
    -- @usage Customer = Class('Customer')
    -- Customer.balance = 100
    -- Customer:overload("pay", Number, function(amount)
    --      self.balance = self.balance - amount
    -- end)
    -- Customer:overload("pay", Number, Number, function(amount, tip)
    --      self.balance = self.balance - (amount / 100 * tip)
    -- end)
    -- Customer:pay(10) -- pay no tip
    -- Customer:pay(10, 15) -- pay with 15% tipS
    function Class:overload(field, ...)
        local func = select(select("#", ...), ...)
        -- Before anything, we need to proceed with proper assertions
        assert(type(func) == "function", ("Final argument of :overload is not a function"))
        assert(self:isPrototype(), ("Attempt to declare overload <%s> outside of prototype"):format(field))
        assert(not (traits[DECL_FLAGS.private] and traits[DECL_FLAGS.protected]), ("Private and protected declaration is not permitted"))
        assert(not (traits[DECL_FLAGS.static]), ("Static declaration is not permitted for overloads"))
        
        -- Generate a signature through the middle arguments, e.g (name, ... = [Number, String], function)
        local args = {...}
        table.remove(args)
        local signature = GenerateSignature(name, unpack(args))
        
        -- A field prototype can only be an overload if it has more than one overload defined. A regular
        -- function may not be converted into an overload.
        local value = self[field]
        if value then
            assert(type(value.ref) == "function" and TableSize(value.overloads) >= 1, ("Attempt to declare function <%s> as overload"):format(field))
            value.overloads[signature] = func
        else
            self[field] = {
                ref        = (function() --[[ placeholder function ]] end),
                accessors  = {},
                overloads  = {[signature] = func},     
                class      = self.proxy or Prototype, 
                traits     = traits
            }
        end
        
    end
    
    
    --- Creates an semi-immutable clone of a class prototype. New fields may not be declared after this
    -- point, but existing public fields may be modified. If the prototype has a constructor
    -- (a function named `construct`), then :new will call it with any arguments passed.
    -- @within Class
    -- @tparam ... arguments Constructor arguments
    -- @return Instantiated class
    function Class:new(...)
        assert(self:isPrototype())
        local newClass = DeepCopy(Class)
        newClass.decl = false
        
        local newProxy = newproxy(true)
        local proxyMetatable = getmetatable(newProxy)
        -- In order for __index to use the new class rather than the prototype, we must
        -- forward the class in the classObject argument.
        proxyMetatable.__index = function(_, key)
            return Metatable.__index(newProxy, key, newClass)
        end
        proxyMetatable.__newindex = function(_, key, new)
            return Metatable.__newindex(newProxy, key, new, newClass)
        end
        
        for op, _ in pairs(META_OPS) do
            proxyMetatable[op] = (function(...) return Metatable[op](...) end)
        end
        
        newClass.proxy = NewProxy
        newClass.proto = Prototype
        
        -- Call the class's constructor if it has one
        if newClass:hasFunction("construct") then
            newProxy:construct(...)
        end
        return newProxy
    end

    --- Creates a metamethod override on the class. Override is especially useful for
    -- utility classes, such as a string which may override the addition metamethod.
    -- The function is treated as a class function, with the first argument passed always being a
    -- class wrapper which allows access to private and protected members.
    -- @within Class
    -- @tparam string op Metamethod
    -- @tparam function func Function
    -- @usage String = Class('String')
    -- String.private.value = "RDX"
    -- String:override("tostring", function(self)
    --      return self.value
    -- end)
    --
    -- print(String:new()) -- prints "RDX"
    function Class:override(op, func)
        local op = FindOpFromAlias(op)
        assert(self:isPrototype(), ("Attempt to modify metamethod <%s> outside of prototype"):format(op))
        assert(op, ("Unable to override unknown metamethod alias <%s>"):format(op))
        if func then
            Metatable[op] = (function(proxy, ...)
                return func(CreateFunctionWrapper(proxy, self), ...)
            end)
        else
            Metatable[op] = nil
        end
    end
    
    --- Removes a metamethod override.
    -- @within Class
    -- @tparam string op Metamethod
    function Class:revert(op)
        self:override(op, nil)
    end
    
    --- Checks whether or not the given prototype is a superclass.
    -- @within Class
    -- @tparam Class proto Class prototype
    -- @treturn bool
    function Class:instanceOf(proto)
        -- Because :instanceOf is only being called from outside builtin functions, we must
        -- compare our proxy rather than the actual class.
        if proto:getPrototype() == Prototype then return true end
        if not Class.supers[proto] then
            for super, _ in pairs(Class.supers) do
                if super:instanceOf(proto) then
                    return true
                end
            end
            return false
        else
            return true
        end
    end

    --- Returns the class identifier. It is recommended to use :instanceOf or compare class prototypes with
    -- :getPrototype rather than comparing class identifiers as RDX does not prevent classes with identical identifiers.
    -- @within Class
    -- @treturn string Class identifier
    function Class:type()
        return self.id
    end
    
    --- Checks whether or not the class is a prototype.
    -- @within Class
    -- @treturn bool
    function Class:isPrototype()
        return self.decl
    end
    
    --- Returns a reference to the class prototype.
    -- @within Class
    -- @treturn Class
    function Class:getPrototype()  
        return self.proto or Prototype
    end
    
    --- Returns the string representation of the class.
    -- @within Class
    -- @treturn string
    function Class:rep()
        return ("<class %s>"):format(identifier)
    end
    
    --- Checks if the class contains a field.
    -- @within Class
    -- @tparam string field Field name
    -- @treturn bool
    function Class:hasField(field)
        return self[field] ~= nil
    end
    
    --- Checks if the class contains a function.
    -- @within Class
    -- @tparam string field Function name
    -- @treturn bool
    function Class:hasFunction(field)
        local field = self[field]
        if field then
            return type(field.ref) == "function" and TableSize(field.overloads) == 0
        else
            return false
        end
    end
    
    --- Returns a raw representation of a class prototype. Class data is stored as a key-value
    -- dictionary which maps to field prototypes. Internal values may also be retrieved via :raw, such
    -- as Class.supers which contains the class prototype's superclasses.
    -- @within Class
    -- @treturn table Raw class data
    function Class:raw()
        assert(self:isPrototype())
        return DeepCopy(Class)
    end

    --- Class __index override.
    -- Class:__index is fired whenever a class prototype or instantiated object is
    -- directly indexed. Upon being called, __index will attempt to retrieve the indexed field. If the field
    -- does exist, it's traits are validated and it's value returned. __index will behave differently depending
    -- on where it is called -- if it is called within a class function, private and protected members are accessible. If they
    -- are accessed otherwise, an error is thrown.
    -- @function Class:__index
    -- @within Class
    Metatable.__index = function(proxy, key, classObject, inFunc)
        -- First, let's check that we have the key in our store.
        local classObject = classObject or Class
        local value = classObject[key]
        if value then
            -- Before we do anything, we need to check if the value should remain internal.
            -- We can do this by verifying that the value is a valid field container or a
            -- function if not (in which case we wrap it).
            if type(value) ~= "table" then
                assert(type(value) == "function", ("Attempt to access an internal value"))
                -- We won't be able to properly call builtin functions without being able
                -- to access internal class fields. To remedy this, we can call functions inside
                -- a wrapper with the class as we have it in our scope.
                return (function(proxy, ...)
                    -- For functions such as :property, we need to make sure they have our proxy's held traits.
                    success, traits = pcall(function()
                        return proxy._decltraits
                    end)
                    getfenv(value)["traits"] = traits or {}
                    return value(classObject, ...)
                end)
            end
            assert(value.accessors, ("Attempt to access an internal value"))
            
            -- If we are not inside a function, then we may only access public fields.
            if not inFunc and (not proxy:isPrototype()) then
                assert(not value.traits[DECL_FLAGS.private], ("Attempt to access private field <%s>"):format(key))
                assert(not value.traits[DECL_FLAGS.protected], ("Attempt to access protected field <%s>"):format(key))
            end
            
            -- If we are inside a function, then we are allowed to access private fields of our own class and
            -- protected fields from superclasses. This does not apply to prototypes.
            if value.traits[DECL_FLAGS.private] and (not proxy:isPrototype()) then
                assert(value.class == Prototype, ("Attempt to access private field <%s>"):format(key)) 
            end
            if value.traits[DECL_FLAGS.protected] then
                assert(Class:instanceOf(value.class), ("Attempt to access protected field <%s>"):format(key))
            end
             
            if value.accessors.get then
                assert((not proxy:isPrototype()) or value.traits[DECL_FLAGS.static], ("Attempt to access non-static property <%s> in prototype <%s>"):format(key, proxy:type()))
                -- Set our function's environment so that it may access the indexed value for further computation.
                getfenv(value.accessors.get)[key] = value.ref
                -- If the field is a wrapper for a trait, then we need to pass our classObject.
                if DECL_FLAGS[key] then
                    return value.accessors.get(classObject, proxy)
                else
                    return value.accessors.get(CreateFunctionWrapper(proxy, classObject))
                end
            elseif type(value.ref) == 'function' then
                if value.traits[DECL_FLAGS.static] then
                    return value.ref
                elseif TableSize(value.overloads) > 0 then
                    return (function(...)
                        return Class:dispatch(proxy, key, value, classObject, nil, ...)
                    end)
                else
                    -- If the function does not have any overloads and is not static, then we can dispatch it normally.
                    -- In this case, :dispatch is called with the `fastFunc` argument which ignores signature checking
                    -- and proceeds directly to the wrapping and execution of the function.
                    return (function(...)
                        return Class:dispatch(proxy, key, value, classObject, value.ref, ...)
                    end)
                end
            else
                return value.ref
            end
        else
            error(("Object %s has no field %s"):format(proxy:rep(), key))
        end
    end

    --- Class __newindex override.
    -- Class:__newindex is fired whenever a field in a class prototype or instantiated object is created or
    -- modified. If the field does not already exist and the calling class is a prototype, __newindex will create 
    -- the field with the currently active field traits. Like __index, any modification to private or protected fields
    -- outside of a function or prototype is not permitted. The combination of private and protected is not permitted.
    -- @function Class:__newindex
    -- @within Class
    Metatable.__newindex = function(proxy, key, new, classObject, traits, inFunc)
        traits = traits or {}
        classObject = classObject or Class
        
        value = classObject[key]
        if value then
            -- Internal values, especially decl, should be readonly. As described in __index, we may verify that
            -- the value is not internal by verifying that it is a field prototype.
            assert(type(value) == "table" and value.accessors, ("Attempt to modify an internal value"))
            if not Class:instanceOf(value.class) then
                -- If an already-existing field is defined in a superclass, then it may only be modified it's virtual
                assert((not value.traits[DECL_FLAGS.private]) and value.traits[DECL_FLAGS.virtual], ("Attempt to modify protected field <%s> from superclass %s"):format(key, value.class:rep()))
            end
            assert(TableSize(traits) == 0 or proxy:isPrototype(), ("Attempt to declare already-existing field <%s>"):format(key))
            assert(not value.traits[DECL_FLAGS.final], ("Attempt to modify final field <%s>"):format(key))
            if not inFunc and (not proxy:isPrototype()) then
                assert(not value.traits[DECL_FLAGS.private], ("Attempt to modify private field <%s>"):format(key))
                assert(not value.traits[DECL_FLAGS.protected], ("Attempt to modify protected field <%s>"):format(key))
            end
            if value.accessors.set then
                -- Set accessors are given the function environment variables value, a placeholder retrieved
                -- as the final value, and the value name as a reference to the actual value.
                getfenv(value.accessors.set)['value'] = new
                getfenv(value.accessors.set)[key] = value.ref
                value.accessors.set(CreateFunctionWrapper(proxy, classObject))
                -- After calling the accessor, any change to value is assumed to be registered in the function's environment
                classObject[key].ref = getfenv(value.accessors.set)[key]
                return
            end

            classObject[key].ref = new
        else
            -- New values may only be declared within the prototype. Declarations in instantiated objects will result
            -- in an error. Private and protected must also be isolated.
            assert(proxy:isPrototype(), ("Attempt to declare field <%s> outside of prototype"):format(key))
            assert(not (traits[DECL_FLAGS.private] and traits[DECL_FLAGS.protected]), ("Private and protected declaration is not permitted"))
            
            -- We're in the clear to append it to the prototype.
            classObject[key] = {
                ref        = new,
                accessors  = {},
                overloads  = {},     
                class      = classObject.proxy or Prototype, 
                traits     = traits,
            }
        end
        
        
    end
    Metatable.__metatable = ("<protected metatable %s>"):format(tostring(Prototype))
    Metatable.__tostring = function(class) return ("<class %s>"):format(identifier) end
    
    --[[
    Class.[private, protected, virtual, final, static]() are syntactic sugars for
    declaring fields and functions. A wrapper of the class is returned
    that associates any modification with the given trait.
    
    e.g. foo.private.secret = 0xDEADBEEF
    Wrappers may also be stacked, e.g. foo.private.virtual.secret = 0xDEADBEEF
    ]]
    --- Class traits
    -- @section Traits
    local TraitWrapper = CreateDeclWrapper(Class, Prototype, DECL_FLAGS.static)
    CreateDeclWrapper(Class, TraitWrapper, DECL_FLAGS.final)
    
    --- Private trait wrapper.
    -- Declaring a field with the `private` trait will ensure that the declared field
    -- may only be accessed by functions from within the class. This restriction does not apply
    -- to class prototypes.
    -- @field Class.private
    -- @within Traits
    -- @usage Customer = Class('Customer')
    -- Customer.private.balance = 10
    -- function Customer:getBalance()
    --      return self.balance
    -- end
    -- 
    -- print(Customer:getBalance()) -- 10
    -- print(Customer.balance) -- error
    TraitWrapper:property('private', {get = function(self, proxy) return CreateDeclWrapper(self, proxy, DECL_FLAGS.private) end, set = function() end})
    --- Protected trait wrapper.
    -- Declaring a field with the `protected` trait will ensure that the declared field
    -- may only be accessed from functions within the defining class and any subclasses. This
    -- restriction does not apply to class prototypes.
    -- @field Class.protected
    -- @within Traits
    -- @usage Person = Class('Person')
    -- Person.protected.ssn = 500
    -- Worker = Class('Worker', Person)
    -- function Worker:makePayment()
    --      makePayment(self.ssn)
    -- end
    TraitWrapper:property('protected', {get = function(self, proxy) return CreateDeclWrapper(self, proxy, DECL_FLAGS.protected) end, set = function() end})
    --- Virtual trait wrapper.
    -- By default, fields from superclasses may not be modified by subclasses. This behavior may be
    -- overriden by declaring fields with the `virtual` field trait.
    -- @field Class.virtual
    -- @within Traits
    -- @usage Salary = Class('Salary')
    -- function Salary.virtual:defaultSalary()
    --      return 100
    -- end
    -- Lawyer = Class('Lawyer', Salary)
    -- function Lawyer:defaultSalary()
    --      return Salary.defaultSalary(self) + 500
    -- end
    TraitWrapper:property('virtual', {get = function(self, proxy) return CreateDeclWrapper(self, proxy, DECL_FLAGS.virtual) end, set = function() end})
    --- Static trait wrapper.
    -- Fields declared with the `static` trait are returned as-is.
    -- @field Class.static
    -- @within Traits
    -- @usage Calculator = Class('Calculator')
    -- Calculator.static.pi = 3.14
    -- MyCalculator = Calculator:new()
    -- print(MyCalculator) -- 3.14
    TraitWrapper:property('static', {get = function(self, proxy) return CreateDeclWrapper(self, proxy, DECL_FLAGS.static) end, set = function() end})  
    --- Final trait wrapper.
    -- Fields declared with the `final` trait may not be modified after they are created under any
    -- circumstance, even within the class prototype.
    -- @field Class.final
    -- @within Traits
    -- @usage Lobby = Class('Lobby')
    -- Lobby.final.size = 20
    -- Lobby.size = 30 -- error
    TraitWrapper:property('final', {get = function(self, proxy) return CreateDeclWrapper(self, proxy, DECL_FLAGS.final) end, set = function() end})
    
    --[[
        Before we return the prototype, we need to properly inherit the given classes.
        We may do this by copying the superclass's fields and appending them to our own.
    ]]
    for _, class in pairs({...}) do
        assert(pcall(class.type, class), ('Class <%s> passed to constructor is not a valid class'):format(tostring(v)))
        for k, v in pairs(class:raw()) do
            if type(v) == 'table' and v.ref then
                Class[k] = {
                    ref        = v.ref,
                    accessors  = DeepCopy(v.accessors),
                    overloads  = DeepCopy(v.overloads),     
                    class      = class, 
                }
            end
        end
        Class.supers[class] = true
    end
    
    return Prototype
end

PRIMITIVE_TO_CLASS = require (RDX_ROBLOX and script.Parent.Primitives or 'primitives')
