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
}

function Class(Identifier, ...)
    --[[
    The tangential class variable shall never be accessed outside
    of the initial base class constructor -- it's sole purpose is for registering and
    storing functions, values, and references. The benefit of diverging the metatable
    of the class into a proxy is that any form of index will *always* be triggered and subsequently validated.
    ]]
    local Class = {oid = Identifier, id = Identifier, supers = {}, decl = true}
    local Proxy = newproxy(true)
    local Metatable = getmetatable(Proxy)
    local Overrides = {}
    
    -- Weak table for faster indexing of signatures
    local SignatureCache = setmetatable({}, {__mode = 'v'})

    --[[
    GenerateSignature will create a signature string with the given class, value name, and
    further arguments. Similar to C++, signatures are key to ensuring that functions with the
    same name or overloads are properly differentiated by the dispatcher.
    ]]
    local function GenerateSignature(ref, class, name, ...)
        if SignatureCache[ref] then return SignatureCache[ref] end
        local ArgString = ""
        for _, arg in pairs({...}) do
            if RDX_ROBLOX and type(arg) == 'table' and ROBLOX_TO_CLASS[arg] then
                arg = ROBLOX_TO_CLASS[arg]
            end
            
            assert(type(arg) == "userdata", ('Registered function <%s> may not use builtin type <%s> as argument'):format(name, type(arg)))
            success, ret = pcall(arg.type, arg)
            if success then
                ArgString = ArgString .. ret
            else
                error(('Unknown userdata <%s> passed as argument to registered function <%s>'):format(str(arg), name))
            end
        end
        
        local Signature
        -- If the ref type is a function, we'll want to append it's class as superclasses
        -- may have functions of the same name, e.g. Person.speak(StudentObject, 'Hello!')
        if type(ref) == 'function' then
            Signature = ('Function%s'):format(class)
        else
            Signature = ('Field%s'):format(name)
        end
        Signature = Signature .. ArgString
        SignatureCache[ref] = Signature
        return Signature
    end
    
    local function FindMatchingSignature(signature)
    end
    
    local function CreateDeclWrapper(self, flag)
        assert(pcall(self.type, self), 'Object passed to declarator is not a valid class')
        
        if (self._decltraits) then
            assert(not self.decltraits[DECL_FLAGS.fast], 'Active trait fast must be isolated')
            -- We're dealing with an existing wrapper. All we need to do is append our trait.
            self._decltraits[flag] = true
        else
            local Store = {_decltraits = {flag = true}} 
            local Wrapper = newproxy(true)
            setmetatable(Wrapper, Metatable)
            local WrapperMetatable = getmetatable(mt)
            WrapperMetatable.__metatable = ("<protected trait wrapper metatable %s>"):format(str(Store))
            WrapperMetatable.__index = function(class, key)
                return Store[key] or Metatable.__index(Class, key)
            end
            
            WrapperMetatable.__newindex = function(class, key, val)
                if Store[key] then Store[key] = val end
                Metatable.__newindex(Class, key, val, Store._decltraits)
            end
            
            return Wrapper
        end
    end
    
    function Class:dispatch(class, name, func, store, fastFunc, ...)
        assert(Class ~= class, ('Attempt to dispatch function <%s> from prototype <%s>'):format(str(func), self:type()))
        assert(self:instanceOf(class), ('Attempt to dispatch function <%s> from unrelated class <%s>'):format(str(func), self:type()))
        -- First, let's see if we can find a function with a matching signature.
        local Match = fastFunc or FindMatchingSignature(GenerateSignature(func, name, ...))
        if Match then
            -- Let's create a new proxy that properly handles protected fields for functional use
            Wrapper = newproxy(true)
            setmetatable(Wrapper, Metatable)
            WrapperMetatable = getmetatable(Wrapper)
            WrapperMetatable.__index = function(class, key)
                Metatable.__index(class, key, store, true)
            end
            WrapperMetatable.__metatable = ('<protected class function wrapper metatable %s>'):format(str(Wrapper))
            
            Match.ref(Wrapper, ...)
        else
            error(('Unable to dispatch function <%s> with given arguments'):format(name))
        end
    end

    
    function Class:get(class, key)
        -- First, let's check that we even have the key.
    end
    
    function Class:set(key, value, raw)
    end

    --[[
    Inspired by C#, Properties are fields in a class that will act upon accessors get and set.
    The traits argument should be a dictionary containing "get", "set", and
    their corresponding functions. Accessor functions are called with environment variables:
        - The property name (a proxy which will process raw set operations)
        - "value", the actual value in an index operation
    
    e.g. Class:property "name" {
        set = function() name = value end
        get = function() return name end
    }
    ]]
    function Class:property(name, traits)
    end
    
    --[[
    Class:[private, protected, virtual, final, static]() are syntactic sugars for
    declaring fields and functions. A wrapper of the class is returned
    that associates any modification with the given trait.
    
    e.g. foo.private.secret = 0xDEADBEEF
    Wrappers may also be stacked, e.g. foo.private.virtual.secret = 0xDEADBEEF
    Functions are able to use a "sweeter" syntax, e.g.
    foo:private().secret = function(self) [...] end
    ]]
    function Class:private()
        return CreateDeclWrapper(self, DECL_FLAGS.private)
    end
    
    function Class:virtual()
        return CreateDeclWrapper(self, DECL_FLAGS.virtual)
    end
    
    function Class:protected()
        return CreateDeclWrapper(self, DECL_FLAGS.protected)
    end
    
    function Class:static()
        return CreateDeclWrapper(self, DECL_FLAGS.static)
    end
    
    function Class:final()
        return CreateDeclWrapper(self, DECL_FLAGS.final)
    end
    
    --[[
    Class:new will create an semi-immutable clone of the prototype, with the 
    exemption of the :new method. New fields may not be declared after this point, but existing public
    fields may be modified. Additionaly, a new wrapper will be created that will call prototype
    metamethods with the Class function variable set to the clone as to properly validate field traits.
    ]]
    function Class:new()
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
    end

    function Class:type()
        return Class.id
    end
    
    function Class:isPrototype()
        return Class.decl
    end

    Metatable.__index = function(class, key, store, inFunc)
        -- First, let's check that we even have the key.
        local store = store or Class
        local Value = store[key]
        
        if Value then
            -- Now that we have the value, we can validate the traits.
            -- If we're not inside a function, only public fields should be visible.
            if not inFunc then
                assert(not Value.traits[DECL_FLAGS.private], ("Attempt to access private field <%s>"):format(key))
                assert(not Value.traits[DECL_FLAGS.protected], ("Attempt to access protected field <%s>"):format(key))
            end
            
            if Value.traits[DECL_FLAGS.private] and (not class:isPrototype()) then
                assert(Value.class == Class, ("Attempt to access private field <%s>"):format(key)) 
            end
            if Value.traits[DECL_FLAGS.protected] then
                assert(Class:instanceOf(Value.class), ("Attempt to access protected field <%s>"):format(key))
            end
            
            if Value.accessors.get then
                -- Set our value name for the accessor to use
                getfenv(Value.accessors.get)[key] = Value.ref
                return Value.accessors.get()
            elseif type(Value.ref) == 'function' then
                if #Value.overloads > 1 then
                    return (function(...)
                        Class:dispatch(class, key, Value.ref, store, nil, ...)
                    end)
                else
                    return (function(...)
                        Class:dispatch(class, key, Value.ref, store, Value.ref, ...)
                    end)
                end
            else
                return Value.ref
            end
        else
            error(("Object <%s> has no field %s"):format(str(class), key))
        end
    end

    
    Metatable.__newindex = function(class, key, new, store, traits)
        traits = traits or {}
        
        -- If the value already exists within our class, let's make sure we're not re-declaring it.
        Value = store[key]
        if Value then
            assert(traits == {}, ('Attempt to declare already-existing field <%s>'):format(key))
            if Value.accessors.set then
                -- We have an accessor. Let's fix it's environment and run it.
                getfenv(Value.accessors.set)['value'] = new
                getfenv(Value.accessors.set)[key] = Value
                -- Now we can call it and fetch the new value
                Value.accessors.set()
                store[key] = getfenv(Value.accessors.set)[key]
                return
            end
            assert(not Value.traits[DECL_FLAGS.final], ("Attempt to modify final field <%s>"):format(key))
        else
            assert(class:isPrototype(), ("Attempt to declare field <%s> outside of prototype"):format(key))
            -- We're dealing with a new value. First, let's validate the fields.
        end
        
        
    end
    Metatable.__metatable = ("<protected metatable %s>"):format(str(Proxy))
    

    --[[
        Before we return the prototype, we need to properly inherit the given classes.
        We may do this by copying the superclass and appending them to our own with
        the appropriate flags. If a function or value has the same signature, an error *will*
        be thrown.
    ]]
    for _, v in pairs({...}) do
        assert(pcall(v.type, v), ('Class <%s> passed to constructor is not a valid class'):format(str(v)))
        local function WalkClass(class) end
        WalkClass(v)
    end
    
    return Proxy
end