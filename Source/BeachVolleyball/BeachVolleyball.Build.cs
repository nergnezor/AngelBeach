using UnrealBuildTool;

public class BeachVolleyball : ModuleRules
{
	public BeachVolleyball(ReadOnlyTargetRules Target) : base(Target)
	{
		PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;

		PublicDependencyModuleNames.AddRange(new string[]
		{
			"Core",
			"CoreUObject",
			"Engine",
			"InputCore",
			"ProceduralMeshComponent",
			"Niagara",
			"AngelscriptCode"
		});

		PrivateDependencyModuleNames.AddRange(new string[]
		{
			"Slate",
			"SlateCore"
		});

		if (Target.Platform == UnrealTargetPlatform.Android)
		{
			// Play Console flags an outdated "Play Billing Library version AIDL"
			// even though this game has no IAP. Community-documented workaround:
			// depend on a current billingclient version explicitly. See the XML.
			AdditionalPropertiesForReceipt.Add("AndroidPlugin",
				System.IO.Path.Combine(ModuleDirectory, "Android", "AndroidBillingFix_UPL.xml"));
		}
	}
}
