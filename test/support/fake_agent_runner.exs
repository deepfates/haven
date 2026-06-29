[scenario, workspace | _] = System.argv() ++ ["streaming", File.cwd!()]

Haven.FakeACPAgent.run(scenario, workspace)
