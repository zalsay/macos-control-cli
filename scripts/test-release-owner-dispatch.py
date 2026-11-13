#!/usr/bin/env python3
"""Offline overload regression compiling actual App adapters against a Core double.
Does not launch Safarier or claim identity/cleanup behavior is validated.
"""
from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='sf-release-dispatch-') as temp:
    out=Path(temp)
    registry=(root/'Sources/Safarier/Automation/RegisteredRunnerRegistry.swift').read_text()
    wrapper=registry[registry.index('actor RegisteredManagerEndpoint:'):].rsplit('#endif',1)[0]
    (out/'Wrapper.swift').write_text('import Foundation\nimport SafarierCore\n'+wrapper)
    fixture=root/'Tests/Fixtures/ReleaseOwnerDispatch'
    subprocess.run(['swiftc','-swift-version','5','-emit-module','-emit-library','-module-name','SafarierCore',str(fixture/'Core.swift'),'-o',str(out/'libSafarierCore.dylib'),'-emit-module-path',str(out/'SafarierCore.swiftmodule')],check=True,timeout=60)
    subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-I',temp,'-L',temp,'-lSafarierCore','-Xlinker','-rpath','-Xlinker',temp,str(root/'Sources/Safarier/Automation/AutomationManagerEndpoint.swift'),str(out/'Wrapper.swift'),str(fixture/'Main.swift'),'-o',str(out/'regression')],check=True,timeout=60)
    subprocess.run([str(out/'regression')],check=True,timeout=5)
