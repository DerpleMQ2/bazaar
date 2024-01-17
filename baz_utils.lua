function FormatTime(time)
    local days = math.floor(time / 86400)
    local hours = math.floor((time % 86400) / 3600)
    local minutes = math.floor((time % 3600) / 60)
    local seconds = math.floor((time % 60))
    return string.format("%d:%02d:%02d:%02d", days, hours, minutes, seconds)
end

function GetTableSize(tbl)
    local cnt = 0
    if tbl ~= nil then
        for k, v in pairs(tbl) do cnt = cnt + 1 end
    end
    return cnt
end

function NoComma(numString)
    if not numString then return "" end

    return numString:gsub(",", "")
end

function FormatInt(number)
    if not number then return "" end

    ---@diagnostic disable-next-line: undefined-field
    local i, j, minus, int, fraction = tostring(number):find('([-]?)(%d+)([.]?%d*)')

    -- reverse the int-string and append a comma to all blocks of 3 digits
    int = int:reverse():gsub("(%d%d%d)", "%1,")

    -- reverse the int-string back remove an optional comma and put the
    -- optional minus and fractional part back
    return minus .. int:reverse():gsub("^,", "") .. fraction
end

function GetDateString(epoch)
    return string.format("%s", os.date('%Y-%m-%d %H:%M:%S', epoch))
end

function GetDayString(epoch)
    return string.format("%s", os.date('%Y-%m-%d', epoch))
end

function GetDayTable(epoch)
    return { year = os.date('%Y', epoch), month = os.date('%m', epoch), day = os.date('%d', epoch), }
end
