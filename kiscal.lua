local DBI

local SHOW_NAMES_LIST = true

local CSS = [[
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: serif; padding: 20px; }
.header { text-align: center; margin-bottom: 24px; }
.header h1 { font-size: 1.6em; margin-bottom: 4px; }
.selector { display: flex; justify-content: center; align-items: center; gap: 8px; margin: 20px 0; flex-wrap: wrap; }
.selector a { text-decoration: none; font-size: 1.4em; padding: 2px 8px; border-radius: 4px; }
.section { border-radius: 10px; padding: 20px; margin-bottom: 24px; overflow-x: auto; }
.section h2 { font-size: 1.15em; margin-bottom: 12px; }
table.shifts { width: 100%; border-collapse: collapse; font-size: 0.88em; }
table.shifts th { padding: 8px 10px; text-align: left; border-bottom: 2px solid; white-space: nowrap; }
table.shifts td { padding: 7px 10px; border-bottom: 1px solid; }
table.shifts td.period { font-weight: 600; white-space: nowrap; }
table.shifts td.zast { color: #b45309; font-size: 0.92em; }
table.shifts td.repl { color: #0369a1; font-size: 0.92em; }
table.cal { width: 100%; border-collapse: collapse; table-layout: fixed; box-shadow: 0 2px 8px rgba(0,0,0,0.15); }
table.cal th { padding: 8px 4px; text-align: center; font-size: 0.85em; border: 1px solid; background: #555; color: #fff; }
table.cal td { border: 1px solid; vertical-align: top; min-height: 110px; padding: 4px 5px; }
table.cal tr.hlrow td { border-top: 1px solid; border-left: 1px solid; border-right: 1px solid; border-bottom: none; padding: 0; min-height: 0; background: transparent; }
table.cal tr.noborder td { border-top: none; }
table.cal .hlday { position: relative; height: 1em; }
table.cal .hlseg { position: absolute; top: 0; bottom: 0; background: #facc15; }
table.cal .daynum { font-weight: 700; font-size: 0.9em; margin-bottom: 1px; }
table.cal .pos { font-size: 0.72em; line-height: 1.4; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
table.cal .pos.sub { color: #b45309; font-weight: 600; }
table.cal .pos.reg { }
.legend { font-size: 0.82em; margin-top: 8px; }
.legend span.sub { color: #b45309; font-weight: 600; }
.names { display: flex; flex-wrap: wrap; gap: 6px; justify-content: center; }
.names a { display: inline-block; padding: 4px 10px; border-radius: 5px; text-decoration: none; font-size: 0.85em; border: 1px solid; background: #555; color: #fff; }
.names a:link, .names a:visited { color: #fff; }
.names a.active { background: #facc15; color: #000; border-color: #a16207; font-weight: 600; }
]]

local MONTHS_CZ = {
    'Leden', 'Unor', 'Brezen', 'Duben', 'Kveten', 'Cerven',
    'Cervenec', 'Srpen', 'Zari', 'Rijen', 'Listopad', 'Prosinec'
}
local DAYS_CZ = {'Po', 'Ut', 'St', 'Ct', 'Pa', 'So', 'Ne'}

local function get_param(r, name)
    local val = r:parseargs() or {}
    return val[name]
end

local function html_escape(s)
    if not s then return '' end
    return tostring(s):gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'):gsub('"', '&quot;')
end

local CONFIG_FILE = '/etc/apache2/configurations/kiscal.ini'

local function read_ini(path)
    local cfg = {}
    local f = io.open(path, 'r')
    if not f then return nil end
    for line in f:lines() do
        line = line:gsub('^%s+', ''):gsub('%s+$', '')
        if line ~= '' and line:sub(1, 1) ~= ';' and line:sub(1, 1) ~= '#' then
            local key, val = line:match('^([^=]+)%s*=%s*(.+)$')
            if key then
                cfg[key:gsub('^%s+', ''):gsub('%s+$', '')] = val
            end
        end
    end
    f:close()
    return cfg
end

local function connect()
    local cfg = read_ini(CONFIG_FILE)
    if not cfg then return nil end
    local dbh = DBI.Connect(
        cfg.driver or 'MySQL',
        cfg.database,
        cfg.username,
        cfg.password,
        cfg.host,
        tonumber(cfg.port) or 3306
    )
    if not dbh then return nil end
    dbh:autocommit(true)
    return dbh
end

local function query_users(dbh)
    local st = dbh:prepare('SELECT idUser, jmeno, prijmeni FROM uzivatele WHERE userSmazano = "n"')
    st:execute()
    local users = {}
    while true do
        local r = st:fetch(true)
        if not r then break end
        users[tonumber(r.idUser)] = { first = r.jmeno, last = r.prijmeni }
    end
    st:close()
    return users
end

local function query_kis_users(dbh)
    local sql = 'SELECT idUser, jmeno, prijmeni FROM uzivatele WHERE userSmazano = "n" AND kategorie = "KIS" ORDER BY prijmeni, jmeno'
    local st = dbh:prepare(sql)
    if not st then return {} end
    st:execute()
    local list = {}
    while true do
        local r = st:fetch(true)
        if not r then break end
        list[#list+1] = { id = tonumber(r.idUser), first = r.jmeno, last = r.prijmeni }
    end
    st:close()
    return list
end

local function query_shifts(dbh, table_name, year, month)
    local sql = string.format([[
        SELECT
            DATE_FORMAT(s.sluzbaOdDate, '%%Y-%%m-%%d') AS datumOd,
            DATE_FORMAT(s.sluzbaDoDate, '%%Y-%%m-%%d') AS datumDo,
            DATE_FORMAT(s.sluzbaOdDate, '%%H:%%i') AS casOd,
            DATE_FORMAT(s.sluzbaDoDate, '%%H:%%i') AS casDo,
            s.sluzbaSever, s.sluzbaJih, s.sluzbaSpojeni, s.sluzbaInformatici
        FROM %s AS s
        WHERE s.mesicSluzba = %d AND s.rok = %d
        ORDER BY s.sluzbaOdDate ASC
    ]], table_name, month, year)
    local st = dbh:prepare(sql)
    st:execute()
    local shifts = {}
    while true do
        local r = st:fetch(true)
        if not r then break end
        local casOd = r.casOd
        local casDo = r.casDo
        if casOd == '23:59' then casOd = '24:00' end
        if casDo == '23:59' then casDo = '24:00' end
        table.insert(shifts, {
            datumOd = r.datumOd, datumDo = r.datumDo,
            casOd = casOd, casDo = casDo,
            sever = tonumber(r.sluzbaSever), jih = tonumber(r.sluzbaJih),
            spojeni = tonumber(r.sluzbaSpojeni), inf = tonumber(r.sluzbaInformatici),
        })
    end
    st:close()
    return shifts
end

local function shifts_on_day(shifts, day_str)
    local result = {}
    for _, s in ipairs(shifts) do
        if s.datumOd <= day_str and day_str <= s.datumDo then
            result[#result+1] = s
        end
    end
    return result
end

local function find_overlapping_substitutes(zastupy, od, doo)
    local result = {}
    for _, z in ipairs(zastupy) do
        if z.datumOd <= doo and z.datumDo >= od then result[#result+1] = z end
    end
    return result
end

local function find_regular_for_sub(sluzba_list, z)
    for _, s in ipairs(sluzba_list) do
        if s.datumOd <= z.datumDo and s.datumDo >= z.datumOd then return s end
    end
    return nil
end

local function days_in_month(y, m)
    return tonumber(os.date('%d', os.time({year=y, month=m+1, day=0})))
end

local function day_of_week(y, m, d)
    local w = tonumber(os.date('%w', os.time({year=y, month=m, day=d})))
    return w == 0 and 7 or w
end

local function name_full(users, uid)
    if not uid or not users[uid] then return nil end
    local u = users[uid]
    return u.first .. ' ' .. u.last
end

local function time_to_min(cas)
    local h, m = cas:match('^(%d+):(%d+)$')
    if not h then return 0 end
    return tonumber(h) * 60 + tonumber(m)
end

local function coverage_on_day(rec, day_str)
    local start_m, end_m
    if day_str == rec.datumOd and day_str == rec.datumDo then
        start_m, end_m = time_to_min(rec.casOd), time_to_min(rec.casDo)
    elseif day_str == rec.datumOd then
        start_m, end_m = time_to_min(rec.casOd), 1440
    elseif day_str == rec.datumDo then
        start_m, end_m = 0, time_to_min(rec.casDo)
    else
        start_m, end_m = 0, 1440
    end
    return start_m, end_m
end

local function duty_intervals(uid, day_str, day_sluzba, day_zastupy)
    local result = {}
    local function add_iv(a, b)
        if b > a then result[#result+1] = {a, b} end
    end
    for _, s in ipairs(day_sluzba) do
        local s_start, s_end = coverage_on_day(s, day_str)
        local subs_by_pos = { sever = {}, jih = {}, spojeni = {}, inf = {} }
        for _, z in ipairs(day_zastupy) do
            for _, pos in ipairs({'sever','jih','spojeni','inf'}) do
                if z[pos] and z[pos] ~= 0 then
                    local zs, ze = coverage_on_day(z, day_str)
                    zs = math.max(zs, s_start)
                    ze = math.min(ze, s_end)
                    if ze > zs then
                        subs_by_pos[pos][#subs_by_pos[pos]+1] = {zs, ze, z[pos]}
                    end
                end
            end
        end
        for _, pos in ipairs({'sever','jih','spojeni','inf'}) do
            local reg = s[pos]
            local subs = subs_by_pos[pos]
            if reg == uid then
                local remaining = {{s_start, s_end}}
                for _, sub in ipairs(subs) do
                    if sub[3] ~= reg then
                        local new = {}
                        for _, iv in ipairs(remaining) do
                            local sa, sb = iv[1], iv[2]
                            if sub[1] > sa then new[#new+1] = {sa, sub[1]} end
                            if sub[2] < sb then new[#new+1] = {sub[2], sb} end
                        end
                        remaining = new
                    end
                end
                for _, iv in ipairs(remaining) do add_iv(iv[1], iv[2]) end
            end
            for _, sub in ipairs(subs) do
                if sub[3] == uid then add_iv(sub[1], sub[2]) end
            end
        end
    end
    return result
end

local function subst_for_pos(zastupy, pos, users)
    local names = {}
    local seen = {}
    for _, z in ipairs(zastupy) do
        local uid = z[pos]
        if uid and uid ~= 0 and not seen[uid] then
            seen[uid] = true
            names[#names+1] = name_full(users, uid) or '-'
        end
    end
    if #names == 0 then return '-' end
    return table.concat(names, '/')
end

function handle(r)
    DBI = require('DBI')
    r.content_type = 'text/html; charset=utf-8'

    local year  = tonumber(get_param(r, 'year'))  or tonumber(os.date('%Y'))
    local month = tonumber(get_param(r, 'month')) or tonumber(os.date('%m'))
    local hl_uid = tonumber(get_param(r, 'highlight'))

    if month < 1 then month = 12; year = year - 1 end
    if month > 12 then month = 1;  year = year + 1 end

    local dbh = connect()
    if not dbh then
        r:puts('<h1>Chyba: Nelze se pripojit k databazi</h1>')
        return apache2.OK
    end

    local users = query_users(dbh)
    local sluzba = query_shifts(dbh, 'sluzba', year, month)
    local zastupy = query_shifts(dbh, 'sluzbazastupy', year, month)
    local kis_users = query_kis_users(dbh)
    dbh:close()

    r:puts([[<!DOCTYPE html>
<html lang="cs">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark light">
<title>KIS - Plan sluzeb - ]] .. MONTHS_CZ[month] .. ' ' .. year .. [[</title>
<style>
]] .. CSS .. [[
</style>
</head>
<body>
]])

    r:puts('<div class="header"><h1>KIS - Plan sluzeb</h1><p>' .. MONTHS_CZ[month] .. ' ' .. year .. '</p></div>')

    local hl_q = hl_uid and ('&highlight=' .. hl_uid) or ''
    local function nav_url(y, m)
        return string.format('?year=%d&month=%d%s', y, m, hl_q)
    end
    r:puts('<div class="selector"><form method="get">')
    r:puts(string.format('<a href="%s">&lt;</a>', nav_url((month == 1) and (year - 1) or year, (month == 1) and 12 or month - 1)))
    r:puts('<select name="month" onchange="this.form.submit()">')
    for i = 1, 12 do
        local sel = (i == month) and ' selected' or ''
        r:puts(string.format('<option value="%d"%s>%s</option>', i, sel, MONTHS_CZ[i]))
    end
    r:puts('</select>')
    r:puts(string.format('<a href="%s">&gt;</a>', nav_url((month == 12) and (year + 1) or year, (month == 12) and 1 or month + 1)))
    r:puts(' &nbsp; ')
    r:puts(string.format('<a href="%s">&lt;</a>', nav_url(year - 1, month)))
    r:puts('<select name="year" onchange="this.form.submit()">')
    for y = 2020, 2030 do
        local sel = (y == year) and ' selected' or ''
        r:puts(string.format('<option value="%d"%s>%d</option>', y, sel, y))
    end
    r:puts('</select>')
    r:puts(string.format('<a href="%s">&gt;</a>', nav_url(year + 1, month)))
    if hl_uid then
        r:puts(string.format('<input type="hidden" name="highlight" value="%d">', hl_uid))
    end
    r:puts('</form></div>')

    if SHOW_NAMES_LIST then
        r:puts('<div class="section"><h2>Lide</h2><div class="names">')
        for _, ku in ipairs(kis_users) do
            local cls = (hl_uid == ku.id) and ' active' or ''
            local params = string.format('?year=%d&month=%d&highlight=%d', year, month, ku.id)
            r:puts(string.format('<a href="%s" class="%s">%s %s</a>', params, cls, html_escape(ku.first), html_escape(ku.last)))
        end
        r:puts('</div></div>')
    end

    -- Calendar
    local ndays = days_in_month(year, month)
    local first_dow = day_of_week(year, month, 1)

    r:puts('<div class="section"><h2>Kalendar</h2><table class="cal">')
    r:puts('<tr>')
    for i = 1, 7 do r:puts('<th>' .. DAYS_CZ[i] .. '</th>') end
    r:puts('</tr>')

    local day = 1
    local started = false
    for week = 1, 6 do
        if day > ndays and not started then break end

        local week_cells = {}
        local has_cell = false
        for dow = 1, 7 do
            if (week == 1 and dow < first_dow) or day > ndays then
                week_cells[dow] = nil
            else
                started = true
                has_cell = true
                local day_str = string.format('%04d-%02d-%02d', year, month, day)
                week_cells[dow] = {
                    day = day,
                    day_str = day_str,
                    day_sluzba = shifts_on_day(sluzba, day_str),
                    day_zastupy = shifts_on_day(zastupy, day_str),
                }
                day = day + 1
            end
        end

        if not has_cell then break end

        if hl_uid and has_cell then
            r:puts('<tr class="hlrow">')
            for dow = 1, 7 do
                local cell = week_cells[dow]
                if not cell then
                    r:puts('<td></td>')
                else
                    local ivs = duty_intervals(hl_uid, cell.day_str, cell.day_sluzba, cell.day_zastupy)
                    r:puts('<td><div class="hlday">')
                    for _, iv in ipairs(ivs) do
                        local left = iv[1] / 1440 * 100
                        local width = (iv[2] - iv[1]) / 1440 * 100
                        r:puts(string.format('<div class="hlseg" style="left:%.2f%%;width:%.2f%%"></div>', left, width))
                    end
                    r:puts('</div></td>')
                end
            end
            r:puts('</tr>')
        end

        local row_cls = ''
        if hl_uid and has_cell then row_cls = ' class="noborder"' end
        r:puts('<tr' .. row_cls .. '>')
        for dow = 1, 7 do
            local cell = week_cells[dow]
            if not cell then
                r:puts('<td class="empty"></td>')
            else
                local day_sluzba = cell.day_sluzba
                local day_zastupy = cell.day_zastupy
                local day_num = cell.day

                local content = string.format('<div class="daynum">%d</div>', day_num)

                for si, sv in ipairs(day_sluzba) do
                    local function fmt_dt(datum, cas)
                        return string.format('%s.%s.%s %s', datum:sub(9,10), datum:sub(6,7), datum:sub(1,4), cas)
                    end
                    local function pos_line(label, uid, zpos, cur_sluzba)
                        local n = name_full(users, uid) or '-'
                        local tz = nil
                        for _, z in ipairs(day_zastupy) do
                            if z[zpos] and z[zpos] ~= 0 and z[zpos] ~= uid then tz = z; break end
                        end
                        local tip = 'Plan: ' .. fmt_dt(cur_sluzba.datumOd, cur_sluzba.casOd) .. ' - ' .. fmt_dt(cur_sluzba.datumDo, cur_sluzba.casDo) .. ' ' .. n
                        if tz and tz[zpos] and tz[zpos] ~= 0 then
                            local sn = name_full(users, tz[zpos]) or '-'
                            local sub_tip = tip .. '\nZastup: ' .. fmt_dt(tz.datumOd, tz.casOd) .. ' - ' .. fmt_dt(tz.datumDo, tz.casDo) .. ' ' .. sn
                            return string.format('<div class="pos sub">* %s <span title="%s">%s</span></div>', label, html_escape(sub_tip), html_escape(sn))
                        else
                            return string.format('<div class="pos reg">  %s <span title="%s">%s</span></div>', label, html_escape(tip), html_escape(n))
                        end
                    end

                    content = content .. pos_line('Svr', sv.sever, 'sever', sv)
                    content = content .. pos_line('Jih', sv.jih, 'jih', sv)
                    content = content .. pos_line('Spo', sv.spojeni, 'spojeni', sv)
                    content = content .. pos_line('Inf', sv.inf, 'inf', sv)
                end

                r:puts('<td>' .. content .. '</td>')
            end
        end
        r:puts('</tr>')
    end

    r:puts('</table>')
    r:puts('<div class="legend"><span class="sub">* zastup</span> = na teto pozici je zastup</div>')
    r:puts('</div>')

    local orig_link = string.format('https://dokumenty.hasici-ol.cz/plansluzeb/kis?datum=%d%02d', year, month)
    r:puts('<div class="section" style="text-align:center"><a href="' .. orig_link .. '" style="display:inline-block;padding:10px 24px;background:#555;color:#fff;border-radius:6px;text-decoration:none;font-size:1.1em">Plan Sluzeb</a></div>')

    r:puts('</body></html>')
    return apache2.OK
end
