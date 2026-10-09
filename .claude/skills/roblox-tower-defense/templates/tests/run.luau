--!strict
-- Runs every template spec under Lune. From the skill folder:
--   lune run templates/tests/run.luau
-- or from anywhere, passing the templates directory:
--   lune run <skill>/templates/tests/run.luau <skill>/templates
local process = require("@lune/process")
local T = require("./TestKit")

T.TEMPLATES = process.args[1] or T.TEMPLATES

require("./PathMath.spec")
require("./Targeting.spec")
require("./EnemyNet.spec")
require("./RemoteGuard.spec")
require("./ReceiptHandler.spec")

process.exit(if T.summary() == 0 then 0 else 1)
