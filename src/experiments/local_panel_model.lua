-- Label changes are confined to the local experiment's model factory.
return function(create_model)
    return function()
        local m=create_model()
        local text=m.text
        function m.text(key,language)
            if key=='dynamic_spawn' or key=='dynamic_spawn_short' then
                return (language or m.language)=='en' and 'Soft limit (test)' or '软门槛（测试）'
            end
            return text(key,language)
        end
        return m
    end
end
