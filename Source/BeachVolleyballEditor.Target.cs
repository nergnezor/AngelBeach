using UnrealBuildTool;
using System.Collections.Generic;

public class BeachVolleyballEditorTarget : TargetRules
{
	public BeachVolleyballEditorTarget(TargetInfo Target) : base(Target)
	{
		Type = TargetType.Editor;
		DefaultBuildSettings = BuildSettingsVersion.V6;
		IncludeOrderVersion = EngineIncludeOrderVersion.Latest;
		ExtraModuleNames.Add("BeachVolleyball");
	}
}
