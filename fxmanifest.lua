fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'H. Zack'
description 'Standalone vehicle lock & ownership with SQL + lockpick + hotwire'
version '1.1.0'

shared_script '@oxmysql/lib/MySQL.lua'

client_script 'client/client.lua'
server_script 'server/server.lua'
