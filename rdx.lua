local RDX_ROBLOX = false
local ROBLOX_TO_CLASS = {
}
local DECL_FLAGS = {
    private = 1,
    virtual = 2,
    protected = 3,
    final = 4,
    static = 5,
}

local META_OPS = {
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

function Class(Identifier, ...)
    --[[
    The tangential class variable shall never be accessed outside
    of the initial base class constructor -- it's sole purpose is for registering and
    storing functions, values, and references. The benefit of diverging the metatable
    of the class into a proxy is that any form of index will *always* be triggered and subsequently validated.
    ]]
    local Class = {originalId = Identifier, id = Identifier, supers = {}, decl = true}
    local Proxy = newproxy(true)
    local Metatable = getmetatable(Proxy)
    local Overrides = {}
    
    -- Weak table for faster indexing of signatures
    local SignatureCache = setmetatable({}, {__mode = 'kv'})
    
    local function DeepCopy(orig)
        local Copy
        if type(orig) == 'table' then
            Copy = {}
            for key, value in next, orig, nil do
                Copy[DeepCopy(key)] = DeepCopy(value)
            end
        else -- number, string, boolean, etc
            Copy = orig
        end
        return Copy
    end
    
    local function TableSize(tbl)
        local Count = 0
        for _ in pairs(tbl) do 
            Count = Count + 1 
        end
        return Count
    end

    --[[
    GenerateSignature will create a signature string with the given class, value name, and
    further arguments. Similar to C++, signatures are key to ensuring that functions with the
    same name or overloads are properly differentiated by the dispatcher.
    ]]
    local function GenerateSignature(name, ...)
        local Signature = name
        for _, arg in pairs({...}) do
            -- Because we do not want to handle builtin datatypes in general, we must extend our coverage to
            -- ROBLOX types alongside Lua types. All ROBLOX datatypes are assumed to be tables.
            if RDX_ROBLOX and type(arg) == "table" and ROBLOX_TO_CLASS[arg] then
                arg = ROBLOX_TO_CLASS[arg]
            end
            
            assert(type(arg) == "userdata", ('Registered function <%s> may not use builtin type <%s> as argument'):format(name, type(arg)))
            success, ret = pcall(arg.type, arg)
            if success then
                Signature = Signature .. ret
            else
                error(('Unknown userdata <%s> passed as argument to registered function <%s>'):format(tostring(arg), name))
            end
        end
        
        return Signature
    end
    
    --[[
    Before any class function is called, CreateFunctionWrapper is called to create a wrapper
    any index operation that w are inside a function as to allow for the access of private and protected fields.
    ]]
    function CreateFunctionWrapper(proxy, class)
        Wrapper = newproxy(true)
        WrapperMetatable = getmetatable(Wrapper)
        WrapperMetatable.__index = function(_, key)
            return Metatable.__index(proxy, key, class, true)
        end
        WrapperMetatable.__newindex = function(...) return Metatable.__newindex(...) end
        WrapperMetatable.__metatable = ('<protected class function wrapper metatable %s>'):format(tostring(Wrapper))
        for op, _ in pairs(META_OPS) do
            WrapperMetatable[op] = function(...) return Metatable[op](...) end
        end
        
        return Wrapper
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
            local Traits = {_decltraits = {[flag] = true}} 
            local Wrapper = newproxy(true)
            local WrapperMetatable = getmetatable(Wrapper)
            WrapperMetatable.__metatable = ("<protected trait wrapper metatable %s>"):format(tostring(Wrapper))
            WrapperMetatable.__index = function(_, key)
                return Traits[key] or Metatable.__index(Wrapper, key, class)
            end
            
            WrapperMetatable.__newindex = function(_, key, val)
                if Traits[key] then Traits[key] = val end
                return Metatable.__newindex(Wrapper, key, val, class, Traits._decltraits)
            end
            
            for op, _ in pairs(META_OPS) do
                WrapperMetatable[op] = function(...) return Metatable[op](...) end
            end
            
            return Wrapper
        end
    end
    
    function Class:dispatch(proxy, name, value, class, fastFunc, ...)
        assert(Proxy ~= proxy, ("Attempt to dispatch function <%s> from prototype <%s>"):format(tostring(name), self:type()))
        assert(self:instanceOf(proxy), ("Attempt to dispatch function <%s> from unrelated class <%s>"):format(tostring(name), self:type()))
        -- We can either use the function provided by fastFunc or the function overloads.
        local Args = {...}
        if Args[1] == proxy then
            table.remove(Args, 1)
        end
        local Match = fastFunc or value.overloads[GenerateSignature(name, unpack(Args))]
        if Match then
            -- If the 
            -- Call the function and return!
            return Match(CreateFunctionWrapper(proxy, class), unpack(Args))
        else
            error(('Unable to dispatch function <%s> with given arguments'):format(name))
        end
    end

    --[[
    Inspired by C#, Properties are fields in a class that will act upon accessors get and set.
    The traits argument should be a dictionary containing "get", "set", and
    their corresponding functions. Accessor functions are called with environment variables:
        - The property name (a proxy which will process raw set operations)
        - "value", the actual value in an index operation
    
    e.g. Class:property "name" {
        set = function() name = value end;
        get = function() return name end;
        default = 0;
    }
    ]]
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
            class      = self.proxy or Proxy, 
            traits     = traits
        }
    end
    
    function Class:overload(name, ...)
        local Function = select(select("#", ...), ...)
        -- Before anything, we need to proceed with proper assertions
        assert(type(Function) == "function", ("Final argument of :overload is not a function"))
        assert(self:isPrototype(), ("Attempt to declare overload <%s> outside of prototype"):format(name))
        assert(not (traits[DECL_FLAGS.private] and traits[DECL_FLAGS.protected]), ("Private and protected declaration is not permitted"))
        
        -- Generate a signature through the middle arguments, e.g (name, ... = [Number, String], function)
        local Args = {...}
        table.remove(Args)
        local Signature = GenerateSignature(name, unpack(Args))
        
        -- A field prototype can only be an overload if it has more than one overload defined. A regular
        -- function may not be converted into an overload.
        local Value = self[name]
        if Value then
            assert(type(Value.ref) == "function" and TableSize(Value.overloads) >= 1, ("Attempt to declare function <%s> as overload"):format(name))
            Value.overloads[Signature] = Function
        else
            self[name] = {
                ref        = (function() --[[ placeholder function ]] end),
                accessors  = {},
                overloads  = {[Signature] = Function},     
                class      = self.proxy or Proxy, 
                traits     = traits
            }
        end
        
    end
    
    --[[
    Class:new will create an semi-immutable clone of the prototype New fields may not be declared after this point, but existing public
    fields may be modified. Additionaly, a new wrapper will be created that will call prototype
    metamethods with the Class function variable set to the clone as to properly validate field traits.
    ]]
    function Class:new()
        assert(self:isPrototype())
        local NewClass = DeepCopy(Class)
        NewClass.decl = false
        
        local NewProxy = newproxy(true)
        local ProxyMetatable = getmetatable(NewProxy)
        -- In order for __index to use the new class rather than the prototype, we must
        -- forward the class in the classObject argument.
        ProxyMetatable.__index = function(_, key)
            return Metatable.__index(NewProxy, key, NewClass)
        end
        ProxyMetatable.__newindex = function(_, key, new)
            return Metatable.__newindex(NewProxy, key, new, NewClass)
        end
        
        for op, _ in pairs(META_OPS) do
            ProxyMetatable[op] = (function(...) return Metatable[op](...) end)
        end
        
        NewClass.proxy = NewProxy
        NewClass.proto = Proxy
        return NewProxy
    end

    --[[
    Class:cast will attempt to cast the current object into the given prototype. If proto is not a direct
    ancestor or was not previously a descendant, an error will be thrown. Instead of permanently converting 
    the current object, a proxy is returned that will forward any meta operation to proto. 
    ]]
    function Class:cast(proto)
        
    end
    
    function Class:override(op, func)
    end
    
    -- Remove override on op
    function Class:revert(op)
    end
    
    function Class:instanceOf(proto)
        -- Because :instanceOf is only being called from outside builtin functions, we must
        -- compare our proxy rather than the actual class.
        if proto:getPrototype() == Proxy then return true end
        if not Class.supers[proto] then
            for super, _ in pairs(Class.supers) do
                if super:instanceOf(proto) then
                    return true
                end
            end
        else
            return true
        end
    end

    function Class:type()
        return self.id
    end
    
    function Class:isPrototype()
        return self.decl
    end
    
    function Class:getPrototype()  
        return self.proto or Proxy
    end
    
    function Class:raw()
        assert(self:isPrototype())
        return DeepCopy(Class)
    end

    Metatable.__index = function(proxy, key, classObject, inFunc)
        -- First, let's check that we have the key in our store.
        local classObject = classObject or Class
        local Value = classObject[key]
        if Value then
            -- Before we do anything, we need to check if the value should remain internal.
            -- We can do this by verifying that the value is a valid field container or a
            -- function if not (in which case we wrap it).
            if type(Value) ~= "table" then
                assert(type(Value) == "function", ("Attempt to access an internal value"))
                -- We won't be able to properly call builtin functions without being able
                -- to access internal class fields. To remedy this, we can call functions inside
                -- a wrapper with the class as we have it in our scope.
                return (function(proxy, ...)
                    -- For functions such as :property, we need to make sure they have our proxy's held traits.
                    success, value = pcall(function()
                        return proxy._decltraits
                    end)
                    getfenv(Value)["traits"] = value or {}
                    return Value(classObject, ...)
                end)
            end
            assert(Value.ref, ("Attempt to access an internal value"))
            
            -- If we are not inside a function, then we may only access public fields.
            if not inFunc and (not proxy:isPrototype()) then
                assert(not Value.traits[DECL_FLAGS.private], ("Attempt to access private field <%s>"):format(key))
                assert(not Value.traits[DECL_FLAGS.protected], ("Attempt to access protected field <%s>"):format(key))
            end
            
            -- If we are inside a function, then we are allowed to access private fields of our own class and
            -- protected fields from superclasses. This does not apply to prototypes.
            if Value.traits[DECL_FLAGS.private] and (not proxy:isPrototype()) then
                assert(Value.class == Proxy, ("Attempt to access private field <%s>"):format(key)) 
            end
            if Value.traits[DECL_FLAGS.protected] then
                assert(Class:instanceOf(Value.class), ("Attempt to access protected field <%s>"):format(key))
            end
             
            if Value.accessors.get then
                assert((not proxy:isPrototype()) or Value.traits[DECL_FLAGS.static], ("Attempt to access non-static property <%s> in prototype <%s>"):format(key, proxy:type()))
                -- Set our function's environment so that it may access the indexed value for further computation.
                getfenv(Value.accessors.get)[key] = Value.ref
                -- If the field is a wrapper for a trait, then we need to pass our classObject.
                if DECL_FLAGS[key] then
                    return Value.accessors.get(classObject, proxy)
                else
                    return Value.accessors.get(CreateFunctionWrapper(proxy, classObject))
                end
            elseif type(Value.ref) == 'function' then
                if Value.traits[DECL_FLAGS.static] then
                    return Value.ref
                elseif TableSize(Value.overloads) > 0 then
                    return (function(...)
                        return Class:dispatch(proxy, key, Value, classObject, nil, ...)
                    end)
                else
                    -- If the function does not have any overloads and is not static, then we can dispatch it normally.
                    -- In this case, :dispatch is called with the `fastFunc` argument which ignores signature checking
                    -- and proceeds directly to the wrapping and execution of the function.
                    return (function(...)
                        return Class:dispatch(proxy, key, Value, classObject, Value.ref, ...)
                    end)
                end
            else
                return Value.ref
            end
        else
            error(("Object <%s> has no field %s"):format(tostring(proxy), key))
        end
    end

    
    Metatable.__newindex = function(proxy, key, new, classObject, traits)
        traits = traits or {}
        classObject = classObject or Class
        
        -- If the value already exists within our class, let's make sure we're not re-declaring it.
        Value = classObject[key]
        if Value then
            -- Internal values, especially decl, should be readonly. As described in __index, we may verify that
            -- the value is not internal by verifying that it is a field prototype.
            assert(type(Value) == "table" and Value.ref, ("Attempt to modify an internal value"))
            assert(#traits == 0, ("Attempt to declare already-existing field <%s>"):format(key))
            assert(not Value.traits[DECL_FLAGS.final], ("Attempt to modify final field <%s>"):format(key))
            if Value.accessors.set then
                -- Set accessors are given the function environment variables value, a placeholder retrieved
                -- as the final value, and the value name as a reference to the actual value.
                getfenv(Value.accessors.set)['value'] = new
                getfenv(Value.accessors.set)[key] = Value.ref
                Value.accessors.set()
                -- After calling the accessor, any change to value is assumed to be registered in the function's environment
                classObject[key].ref = getfenv(Value.accessors.set)[key]
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
                class      = classObject.proxy or Proxy, 
                traits     = traits,
            }
        end
        
        
    end
    Metatable.__metatable = ("<protected metatable %s>"):format(tostring(Proxy))
    Metatable.__tostring = function(class) return ("<class %s>"):format(Identifier) end
    
    --[[
    Class.[private, protected, virtual, final, static]() are syntactic sugars for
    declaring fields and functions. A wrapper of the class is returned
    that associates any modification with the given trait.
    
    e.g. foo.private.secret = 0xDEADBEEF
    Wrappers may also be stacked, e.g. foo.private.virtual.secret = 0xDEADBEEF
    ]]
    local TraitWrapper = CreateDeclWrapper(Class, Proxy, DECL_FLAGS.static)
    CreateDeclWrapper(Class, TraitWrapper, DECL_FLAGS.final)
    TraitWrapper:property('private', {get = function(self, proxy) return CreateDeclWrapper(self, proxy, DECL_FLAGS.private) end, set = function() end})
    TraitWrapper:property('protected', {get = function(self, proxy) return CreateDeclWrapper(self, proxy, DECL_FLAGS.protected) end, set = function() end})
    TraitWrapper:property('virtual', {get = function(self, proxy) return CreateDeclWrapper(self, proxy, DECL_FLAGS.virtual) end, set = function() end})
    TraitWrapper:property('static', {get = function(self, proxy) return CreateDeclWrapper(self, proxy, DECL_FLAGS.static) end, set = function() end})  
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
                    traits     = DeepCopy(v.traits),
                }
            end
        end
        Class.supers[class] = true
    end
    
    return Proxy
end