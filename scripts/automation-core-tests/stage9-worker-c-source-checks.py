from pathlib import Path
root=Path.cwd()
cmd=(root/'Sources/Safarier/Automation/AutomationRequestCommand.swift').read_text()
app=(root/'Sources/Safarier/ManagerGUI/ManagerApp.swift').read_text()
model=(root/'Sources/Safarier/ManagerGUI/ManagerModel.swift').read_text()
core=(root/'Sources/SafarierCore/AutomationScriptCoordinator.swift').read_text()
checks={'intake before suspend':cmd.index('AutomationScriptPendingCommands.count < intakeLimit') < cmd.index('suspendExecution()'), 'manager routing':'ManagerAutomationHooks.dispatch' in cmd, 'combined lifecycle':'ManagerAutomationHooks.combinedPendingWork' in app, 'permission before proxy':model.index('profilePermissionsChanged') < model.index('workspace.proxies.all()'), 'capacity includes workers':'workerSlots' in core, 'typed reserved frontend':'case .cancel, .closeSession: intakeLimit = AutomationLimits.replayEntries' in cmd and 'default: intakeLimit = AutomationLimits.replayEntries - 2' in cmd, 'typed reserved coordinator':'case .cancel, .closeSession: capacity = AutomationLimits.replayEntries' in core and 'default: capacity = AutomationLimits.replayEntries - 2' in core}
for k,v in checks.items(): print(('PASS' if v else 'FAIL'), k)
assert all(checks.values())
