// Beach Volleyball Game Mode - spawn, serve flow, scoring, match restart

class ABeachVolleyballGameMode : AGameModeBase
{
	UPROPERTY(BlueprintReadOnly)
	ABall Ball;

	UPROPERTY(BlueprintReadOnly)
	AHumanPlayer HumanPawn;  // Team A back — AI until gamepad input

	UPROPERTY(BlueprintReadOnly)
	AAIPlayer PlayerA2;  // Team A front

	UPROPERTY(BlueprintReadOnly)
	AAIPlayer PlayerB1;  // Team B back

	UPROPERTY(BlueprintReadOnly)
	AAIPlayer PlayerB2;  // Team B front

	UPROPERTY(BlueprintReadOnly)
	ACourt Court;

	UPROPERTY(BlueprintReadOnly)
	ASandFX SandFX;

	float MatchRestartDelay = 5.0f;

	default HUDClass = ABeachVolleyballHUD;
	default GameStateClass = ABeachVolleyballGameState;
	default DefaultPawnClass = nullptr;

	// Debug: global slow-motion so contact timing / animations are easy to read.
	// Set to 1.0 for normal speed.
	float TimeScale = 1.0f;

	// --- Mobile stand-ins for what Lumen gives desktop for free -----------------
	// Desktop is the reference look; these exist only to let mobile land on the same
	// image. Tune them against a real desktop capture, not by eye — and capture it at
	// FULL quality (MatchFilmer without -es31). The ES3.1 preview is a different
	// picture: it put the body average at (68,44,26) while the actual desktop build
	// renders (71,49,40) in the same shot, so tuning to the preview aims at the wrong
	// target. Mobile currently lands on (68,54,38) against that (71,49,40).
	// NOTE 2026-08-23: confirmed on device that this hemisphere-override trick
	// does not reach mobile character shading at all any more (a 6x-HDR magenta
	// test produced zero tint on the bodies) — mobile's SkyLight needs a real
	// ProcessedTexture cubemap that this fully-dynamic scene never builds. Left
	// in place since it's harmless (still colours the sand/court fine, presumably
	// via a different, non-character path) but don't expect it to touch bodies;
	// the sun-angle change above is what actually fixes body visibility now.
	const FLinearColor SandBounceColor         = FLinearColor(0.55f, 0.30f, 0.12f, 1.0f);
	const float        MobileSkyLightIntensity = 8.0f;  // was 5.2 for the old low sun; some headroom for the new one, not the 16 used to isolate the intensity-alone experiment
	// The SkyLight's UPPER hemisphere captures the dome, which is blue-violet, so a
	// plain intensity boost fills the bodies with cool light. Tinting the SkyLight warm
	// biases it back toward the sand-bounce cast desktop gets from Lumen. Measured on
	// device against the full-quality desktop body average (71,49,40), R/G 1.45:
	//   no tint          -> (56,50,38)  R/G 1.12
	//   (1.0,0.70,0.48)  -> (68,54,38)  R/G 1.26   <- this one
	//   (1.0,0.57,0.33)  -> (66,52,37)  R/G 1.27
	// Note the third row: pushing the tint further moved the body colour *not at all*.
	// Past this point the SkyLight is no longer what decides the body's hue — the
	// mannequin's own near-neutral albedo and the direct sun rim are — so don't reach
	// for a stronger tint here expecting a warmer body. Brightness lands on desktop's
	// number; the residual coolness in R/G would have to come out of the material or
	// the post-process, not this light.
	const FLinearColor MobileSkyLightTint      = FLinearColor(1.0f, 0.70f, 0.48f, 1.0f);

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		Gameplay::SetGlobalTimeDilation(TimeScale);
		SetupWorld();
		SpawnActors();
		StartMatch();
	}

	// Angelscript has no platform macro, so this is the single place that decides
	// what "mobile" means. Everything gated on it is a stand-in for a renderer
	// feature mobile lacks — never a different art direction. Also used by
	// ABeachVolleyballHUD to decide whether to draw the on-screen touch controls.
	UFUNCTION(BlueprintPure)
	bool IsMobilePlatform() const
	{
		FString P = Gameplay::GetPlatformName();
		return P == "Android" || P == "IOS";
	}

	private void SetupWorld()
	{
		// Sun: pitch -90 puts it straight overhead (noon), light travelling
		// straight down — yaw is irrelevant at the zenith. This replaces the
		// earlier low-sunset sun (pitch -6, warm backlit rim); see git history
		// if that mood needs to come back.
		//
		// THE SUN IS THE SAME ON EVERY PLATFORM. Under the old low sun, mobile
		// rendered the players as black silhouettes from the backlighting (body
		// average (12,8,5) on device against (68,44,26) on desktop) — that's
		// what SandBounceColor/MobileSkyLightTint below were built to fix. An
		// overhead sun lights the tops of the players directly on every
		// platform instead of backlighting them, so that specific failure mode
		// should no longer apply, but the mobile fill values were tuned against
		// the old sun angle and have not been re-measured against this one.
		bool bMobile = IsMobilePlatform();

		// Dead-vertical (-90) leaves every camera-facing (roughly horizontal-
		// normal) surface with ZERO direct light, and confirmed on device, ZERO
		// usable indirect light either — mobile's SkyLight does not reach movable
		// skeletal meshes here at all (a magenta LowerHemisphereColor test at 6x
		// HDR produced literally no tint on the bodies: mobile needs a real
		// ProcessedTexture cubemap this fully-dynamic scene never builds).
		// Desktop's Lumen GI papers over the same gap; mobile has nothing to.
		// Regression measured on device: body torso ~(6-28,...) out of 255,
		// i.e. near-black, vs sand/sky rendering correctly the whole time.
		//
		// Tilting the mobile sun 20 degrees off the zenith gives direct light a
		// horizontal component again (sin(20 deg) ~= 0.34 of full) without
		// reverting to the old grazing backlit angle that caused the *original*
		// black-body bug. Yaw 180 matches that old, already-proven sun's facing
		// so the lit side matches the camera's usual framing. Desktop is
		// untouched (still exactly -90) since it was not broken.
		// Fixed, measured on device: body torso ~(89-102,...) out of 255.
		//
		// DESKTOP IS NOW -55, NOT -90. A dead-vertical sun is the flattest light
		// there is: it puts no shadow anywhere the camera can see, gives a standing
		// body no lit side and no shadow side, and leaves sand with no visible
		// relief at all, because relief is only ever visible as shading.
		//
		// -90 was never an art decision. It was a mobile fix: the old low backlit
		// sunset (pitch -6) rendered Android bodies as black silhouettes because
		// mobile has no GI to fill the camera-facing side, and moving the sun
		// overhead is what stopped it. That let the platform with the weakest
		// renderer dictate the look on the platform with the strongest, which is
		// exactly backwards.
		//
		// -55 keeps direct light on the top AND the front of a standing figure
		// (sin 55 = 0.82 of full on a horizontal surface, cos 55 = 0.57 on a
		// vertical one) while throwing shadows long enough to read the ground, and
		// stays far enough from grazing to avoid the specular aliasing a low sun
		// causes on a rough surface. Yaw 200 puts it front-left of the match
		// camera. Yaw 35 puts it BEHIND and to the left of the match camera, which
		// looks down +X from -X. Yaw 200 was tried first and was wrong for exactly
		// one reason: it threw every shadow back TOWARD the camera, where each one
		// hides behind the figure that casts it. The wide shot came back with no
		// readable shadow anywhere on the sand. Shadows only do their job — telling
		// you where a body is standing and how the ground lies — when they fall
		// AWAY from the viewer. Yaw 35 still ran them nearly straight up the screen,
		// where a figure stands on its own shadow; 50 angles them across the frame.
		//
		// Pitch settled at -45 rather than -55 for the same reason: shadow length is
		// height/tan(pitch), so -55 gives a 1.8m player a 1.26m shadow and -45 gives
		// a full 1.8m one. -45 is still far from grazing.
		//
		// DO NOT RAISE THE YAW TO 70. It is not an art constraint, it is a driver
		// one: yaw 70 kills the GPU with VK_ERROR_DEVICE_LOST (invalid read, device
		// fault report) while rendering the close-up reference shot, reproducibly,
		// at both pitch -45 and -55, while yaw 35 and 50 complete the same six-shot
		// series cleanly every time. Bisected one variable at a time. If a wider
		// shadow angle is ever wanted, re-test it the same way rather than assuming
		// the crash was a one-off — it was not.
		//
		// MOBILE IS DELIBERATELY UNTOUCHED at (-70,180): its fill values were tuned
		// against that angle on a real device, and -55 is near enough that the
		// parity gap stays small — which the old low sun would not have been.
		FRotator SunRotation = bMobile ? FRotator(-70, 180, 0) : FRotator(-45, 50, 0);
		ADirectionalLight SunActor = Cast<ADirectionalLight>(
			SpawnActor(ADirectionalLight, FVector(0, 0, 10000), SunRotation));
		if (SunActor != nullptr)
		{
			UDirectionalLightComponent LC = Cast<UDirectionalLightComponent>(
				SunActor.GetComponentByClass(UDirectionalLightComponent));
			if (LC != nullptr)
			{
				// Brighter on desktop now that SkyAtmosphere is actually VISIBLE (it used
					// to render behind the dome): the atmosphere's colour and the sun disc are
					// both driven by this value. Mobile keeps the 6.0 it was measured at.
					LC.SetIntensity(bMobile ? 6.0f : 10.0f);
				LC.SetLightColor(FLinearColor(1.0f, 0.96f, 0.90f));   // midday sun, barely warm
				LC.CastShadows = true;
				LC.SetAtmosphereSunLight(true);                        // visible sun disc for the flare

				// THIS IS WHY MOBILE HAD NO GROUND SHADOWS AT ALL.
				//
				// ADirectionalLight's component defaults to STATIONARY, not Movable
				// (Engine/Private/Light.cpp: DirectionalLightComponent->Mobility =
				// EComponentMobility::Stationary). For a Stationary light,
				// ComputeWholeSceneDynamicShadowRadius() returns
				// DynamicShadowDistanceStationaryLight whenever r.AllowStaticLighting
				// is on — and that field defaults to 0.0
				// (DirectionalLightComponent.cpp:1038), while r.AllowStaticLighting
				// defaults to true and is not overridden anywhere in Config/.
				//
				// So the cascaded-shadow radius was literally ZERO. That is the real
				// reason forcing sg.ShadowQuality 3, r.Shadow.CSM.MaxMobileCascades 4
				// and r.Mobile.EnableStaticAndCSMShadowReceivers 1 over the adb console
				// all changed nothing on device: no CVar can scale a radius of zero.
				// It is also why the procedural shadow-ellipse experiment was written
				// and then reverted — the bug was never in that mesh.
				//
				// Desktop never noticed because DefaultEngine.ini enables Virtual
				// Shadow Maps (r.Shadow.Virtual.Enable=1), which bypass the CSM path
				// entirely. Mobile has no VSM, so mobile had no shadows.
				//
				// Movable takes the DynamicShadowDistanceMovableLight branch instead.
				// 6000 rather than the 40000 default: Android spreads the radius over
				// very few cascades, so 40000 puts the texels at roughly 27cm and a
				// body-width shadow dissolves. 6000 covers the court plus the near
				// sand at ~6cm texels, which actually resolves a player.
				LC.SetMobility(EComponentMobility::Movable);
				LC.SetDynamicShadowDistanceMovableLight(6000.0f);
			}
		}

		// SkyAtmosphere owns the sky: real sun disc (for the lens flare) plus the
		// sunset horizon-glow-to-blue gradient driven by the low sun above.
		SpawnActor(ASkyAtmosphere, FVector::ZeroVector, FRotator::ZeroRotator);

		// Surrounding environment. On desktop this builds ONLY the sea skirt now —
		// SkyAtmosphere owns everything above the waterline. On mobile it is still
		// the whole dome, because mobile has no atmosphere. See Environment.as.
		SpawnActor(AEnvironment, FVector::ZeroVector, FRotator::ZeroRotator);

		if (!bMobile)
		{
			// CLOUDS. An empty gradient is the tell that a sky is a shader and not a
			// place: nothing in it sits at any distance, so it gives the eye no scale
			// and the sun nothing to break through. Clouds also feed the SkyLight's
			// real-time capture, so for the first time the ambient light in the scene
			// comes from the sky that is actually on screen. Engine content — this
			// costs the repo nothing.
			AVolumetricCloud CloudActor = Cast<AVolumetricCloud>(
				SpawnActor(AVolumetricCloud, FVector::ZeroVector, FRotator::ZeroRotator));
			if (CloudActor != nullptr)
			{
				UVolumetricCloudComponent VC = Cast<UVolumetricCloudComponent>(
					CloudActor.GetComponentByClass(UVolumetricCloudComponent));
				if (VC != nullptr)
				{
					UMaterialInterface CloudMat = Cast<UMaterialInterface>(LoadObject(nullptr,
						"/Engine/EngineSky/VolumetricClouds/m_SimpleVolumetricCloud_Inst.m_SimpleVolumetricCloud_Inst"));
					if (CloudMat != nullptr)
						VC.SetMaterial(CloudMat);
					// Fair-weather cumulus: base well above the court, shallow layer, so the
					// clouds sit IN the sky instead of swallowing it.
					// 8km, not 4. The match camera's axis is only ~22 degrees down, so the top
					// of frame sits just a few degrees above the horizon — and a low cloud base
					// puts the SHADED UNDERSIDES of the clouds exactly there. The wide shot came
					// back with a grey lid over a sunlit court. Higher base, and that band is sky.
					// Capped at 6.5: 8.0 reproducibly took the GPU down with VK_ERROR_DEVICE_LOST
					// two runs in a row while rendering the close-up shot.
					VC.SetLayerBottomAltitude(6.5f);   // km
					// A THIN layer. At 5km thick the camera looks along the underside of the
					// clouds at low elevation and sees only their shaded bases, which reads as
					// overcast however sunny the ground is.
					VC.SetLayerHeight(2.5f);
				}
			}

			// One capture at court centre. Lumen reflections fall back to it wherever
			// screen-space traces run off the edge of frame and hardware traces miss,
			// which on a scene this open is most of the horizon.
			SpawnActor(ASphereReflectionCapture, FVector(0, 0, 250), FRotator::ZeroRotator);
		}

		// SkyLight captures the sky for soft ambient fill so the court isn't black.
		ASkyLight SkyLightActor = Cast<ASkyLight>(
			SpawnActor(ASkyLight, FVector(0, 0, 500), FRotator::ZeroRotator));
		if (SkyLightActor != nullptr)
		{
			USkyLightComponent SLC = Cast<USkyLightComponent>(
				SkyLightActor.GetComponentByClass(USkyLightComponent));
			if (SLC != nullptr)
			{
				SLC.SetRealTimeCapture(true);
				// Raised alongside the -1.5 EV exposure cut. The cut is aimed at the
				// sun-lit sand that was clipping; without more ambient it would also
				// crush the players, who are dark-skinned meshes sitting in their own
				// shadow. More fill, less overall exposure: the sand comes down, the
				// bodies do not go to pure black.
				// Desktop drops 3.0 -> 1.0. With real-time capture the SkyLight already
					// carries the true radiance of the sky it captured, so 1.0 IS the physical
					// answer and anything above it is triple-counting the sky. 3.0 was set to
					// stop a -1.5 EV exposure cut from crushing the players — a cut that no
					// longer exists — and its real cost is that it fills every shadow three
					// times too brightly, which flattens exactly the modelling the sun angle
					// was moved to create.
					SLC.SetIntensity(bMobile ? MobileSkyLightIntensity : 1.0f);

				if (bMobile)
				{
					// MOBILE STANDS IN FOR LUMEN HERE.
					//
					// With the sun this low and behind the players, the only thing
					// lighting the side the camera sees is bounce off the sunlit sand.
					// Desktop gets that from Lumen GI; mobile has no GI at all, which is
					// the entire reason the bodies went black there.
					//
					// A SkyLight's lower hemisphere is a flat colour (black by default),
					// so it normally contributes nothing from below. Filling it with the
					// sand's own bounce colour is the standard approximation — the engine
					// says so itself in SkyLightComponent.h: "useful to approximate
					// skylight bounce lighting". One call, no per-frame cost, and it adds
					// exactly the missing term rather than a different look.
					//
					// The colour is the sand albedo (0.62,0.52,0.36 in Court.as) warmed by
					// the sun's own tint and scaled down to bounce strength — sand does not
					// return all of what hits it.
					SLC.SetLowerHemisphereColor(SandBounceColor);
					SLC.SetLightColor(MobileSkyLightTint);
				}
			}
		}

		// (Single directional light only — a second one triggers UE's "competing
		// directional lights" warning. The bright SkyLight fills the shadows.)

		AExponentialHeightFog FogActor = Cast<AExponentialHeightFog>(
			SpawnActor(AExponentialHeightFog, FVector(0, 0, 100), FRotator::ZeroRotator));
		if (FogActor != nullptr)
		{
			UExponentialHeightFogComponent FC = Cast<UExponentialHeightFogComponent>(
				FogActor.GetComponentByClass(UExponentialHeightFogComponent));
			if (FC != nullptr)
			{
				// Thin, distant haze only — NOT a thick coloured band over the court.
				// The previous dense volumetric fog read as smoke, not a sunset.
				//
				// On device the old start distance saturated everything past the
				// court to the inscattering colour: the sea, the far sand and the
				// sky all came out as the same flat cream. Pushing the start out to
				// 3500 clears the court and the near water (~2000-3000 from the
				// match camera), while everything further still fades to warm haze.
				// (That alone did NOT turn the sea blue — the water at that range is
				// unfogged and still rendered warm, because it is reflecting the
				// sky, and the sky was warm haze. Hence the SkyAtmosphere change.)
				//
				// Desktop is thinner AND, crucially, a normal sea-level layer again —
					// see the falloff below.
					// Thinner again now that the world is 200m across instead of 50m. 0.006
					// with a 2200 start was tuned when the sea was a dome 50m away; against a
					// real ocean it saturated the whole surface to flat pale blue within a few
					// tens of metres and erased every wave. Real aerial perspective at these
					// distances is almost nothing.
					FC.SetFogDensity(bMobile ? 0.002f : 0.0022f);
				// Stretching the fog layer upward (falloff 0.5 -> 0.1) was an attempt
				// to make the fog double as the sky on Android, where SkyAtmosphere
				// was switched off. It did not work — the top of frame went from
				// (13,5,3) to (17,8,3), still black — and it made things worse for
				// the sea, because a taller layer means more fog along the near-
				// horizontal view rays that look at the water.
				//
				// Re-enabling SkyAtmosphere for Android did NOT bring a sky back —
				// the top of frame went (17,8,3) -> (7,2,1), i.e. still black and
				// slightly darker, since the falloff went the wrong way at the same
				// time. Mobile really does want an authored sky mesh, so the
				// original comment in AndroidEngine.ini was right after all.
				//
				// That leaves the fog as the sky whether we like it or not, so stop
				// fighting it and make the layer genuinely tall.
				//
				// Note the samples so far do NOT settle this on their own: falloff
				// 0.5 -> top (13,5,3), 0.2 -> (7,2,1), 0.1 -> (17,8,3) is not
				// monotonic, and those shots differ in aspect ratio, framing and
				// whether SkyAtmosphere was on, so "top of frame" is not even the
				// same piece of sky. What they do agree on is that every value in
				// that range leaves a black band, i.e. the seam stays in frame.
				// 0.02 is five times taller than the tallest tried, chosen to put
				// the seam decisively out of frame rather than to interpolate a
				// trend. Court level is unaffected: the fog still starts at 3500.
				// DESKTOP GOES BACK TO A NORMAL FALLOFF. 0.02 is a layer five times
					// taller than the tallest ever tried, and it exists for one reason: on
					// Android the fog had to double as the sky. On desktop it now has a real
					// sky above it, and a layer that tall greys out that sky along every
					// near-horizontal view ray — which is exactly what the wide shot came
					// back looking like: a bright sunlit court under an overcast evening.
					// 0.25 keeps the haze down where the sea is.
					FC.SetFogHeightFalloff(bMobile ? 0.02f : 0.25f);
				// Was a warm (0.9,0.5,0.3) orange to match the old low sunset sun;
				// with the sun overhead there's no horizon glow to match, so this
				// substitute Android "sky" goes neutral midday blue instead.
				FC.SetFogInscatteringColor(FLinearColor(0.55f, 0.68f, 0.85f));
				// Volumetric fog is back ON for desktop. It was off because the fog was
					// standing in for a sky it could never draw, and a dense flat layer read as
					// smoke. With SkyAtmosphere drawing the sky, fog goes back to the job it is
					// actually for: aerial perspective, and shafts where the sun cuts through.
					FC.SetVolumetricFog(!bMobile);
				// Must stay OUTSIDE the sky dome (radius 5000 in Environment.as).
				// Fog saturates to its inscattering colour within a couple of
				// thousand units at this density, so anything it reaches turns warm
				// cream — that is what hid the sea for so long. With the dome now
				// providing the sky, fog has no job left except far-field haze, and
				// starting it past the dome keeps it from bleaching the gradient or
				// the water.
				// 5200 existed only to stay outside the 5000-radius dome. On desktop the
					// dome no longer covers the sky, so fog can come in to where it does some
					// good: 2200 leaves the court and the near sand completely clear (the match
					// camera is 1050 out) while the sea beyond it fades with distance, which is
					// the cue that makes a flat surface read as kilometres instead of metres.
					FC.SetStartDistance(bMobile ? 5200.0f : 4500.0f);
				// Was warm to glow toward the low sunset sun disc; with the sun
				// at the zenith this glow isn't visible from a horizontal camera
				// anyway, so keep it neutral rather than falsely warm.
				FC.SetDirectionalInscatteringColor(FLinearColor(0.95f, 0.95f, 0.9f));
				FC.SetDirectionalInscatteringExponent(8.0f);
			}
		}

		APostProcessVolume PPV = Cast<APostProcessVolume>(
			SpawnActor(APostProcessVolume, FVector::ZeroVector, FRotator::ZeroRotator));
		if (PPV != nullptr)
		{
			PPV.bUnbound = true;
			PPV.Priority = 1.0f;
			FPostProcessSettings PP = PPV.Settings;
			// ---------------------------------------------------------------------
			// THE GRADE. Until now this volume had bloom, an exposure bias, a lens
			// flare and a vignette — and no colour grading of ANY kind: no white
			// balance, no saturation, no contrast, no tone curve. A render with no
			// grade does not look like a photograph of anything, however good the
			// lighting under it is, because no camera has ever produced that image.
			// ---------------------------------------------------------------------

			// --- Bloom. Lower than before: with SkyAtmosphere finally visible there is
			// a real sun disc in frame, and 0.8 around it read as glare rather than lens.
			PP.bOverride_BloomIntensity = true;
			PP.BloomIntensity = 0.55f;
			PP.bOverride_BloomThreshold = true;
			PP.BloomThreshold = 1.0f;

			// --- Physical camera. Exposure and depth of field then both derive from
			// the same three numbers instead of being tuned against each other. f/4 at
			// 1/500s and ISO 100 is a sports lens on a bright day — roughly sunny-16.
			PP.bOverride_CameraShutterSpeed = true;
			PP.CameraShutterSpeed = 500.0f;
			PP.bOverride_CameraISO = true;
			PP.CameraISO = 100.0f;
			PP.bOverride_DepthOfFieldFstop = true;
			PP.DepthOfFieldFstop = 4.0f;

			// --- Exposure. The old settings were a manual bias plus a min/max pair in
			// LEGACY LUMINANCE units, and the long comment justifying them was measured
			// against a scene lit by a fog "sky" that no longer exists AND captured with
			// this machine's scalability pinned to low. All of it is history. This is a
			// histogram auto-exposure with a deliberately WIDE EV100 range: wide enough
			// that it genuinely adapts as the sun, the sky and the materials change
			// through this pass rather than silently clamping and making every later
			// measurement a lie about a different scene.
			PP.bOverride_AutoExposureMethod = true;
			PP.AutoExposureMethod = EAutoExposureMethod::AEM_Histogram;
			PP.bOverride_AutoExposureMinBrightness = true;
			// MEASURED, and the first values were wrong in a way worth recording:
			// 6..18 clamped the whole series ~2.3 stops dark (sand 148 -> 28). The
			// scene does not sit at a photographic EV, because the sun is 10 "lux" on
			// a relative scale rather than the ~100000 of real daylight. Sand at 0.62
			// albedo under a 55-degree 10-lux sun is about 1.6 cd/m2, i.e. EV100 ~3.7,
			// so a floor of 6 pinned it. -2..16 brackets that with room for the sun,
			// sky and materials to move through the rest of this pass.
			PP.AutoExposureMinBrightness = -2.0f;   // EV100
			PP.bOverride_AutoExposureMaxBrightness = true;
			PP.AutoExposureMaxBrightness = 16.0f;   // EV100
			PP.bOverride_AutoExposureBias = true;
			PP.AutoExposureBias = 0.0f;

			// --- Local exposure. A sunlit beach is a genuinely high-dynamic-range
			// subject and a high sun makes it more so, not less: sand near its clipping
			// point in the same frame as a body in its own shadow. Local exposure is
			// what lets both survive one exposure, and it is the single most
			// under-used post-process feature for outdoor work.
			PP.bOverride_LocalExposureHighlightContrastScale = true;
			PP.LocalExposureHighlightContrastScale = 0.8f;
			PP.bOverride_LocalExposureShadowContrastScale = true;
			PP.LocalExposureShadowContrastScale = 0.9f;

			// --- White balance. 6500K is neutral daylight: it keeps the sun white and
			// lets the sky-lit shadows stay blue, which is the honest signature of this
			// sun rather than a filter laid over it.
			PP.bOverride_WhiteTemp = true;
			PP.WhiteTemp = 6500.0f;
			PP.bOverride_WhiteTint = true;
			PP.WhiteTint = 0.0f;

			// --- Tone curve. The default response is close to straight; a film shoulder
			// is what stops bright sand from marching to white in a hard edge, and a toe
			// is what keeps shadows off pure black.
			PP.bOverride_ToneCurveAmount = true;
			PP.ToneCurveAmount = 1.0f;
			PP.bOverride_FilmSlope = true;
			PP.FilmSlope = 0.90f;
			PP.bOverride_FilmToe = true;
			PP.FilmToe = 0.55f;
			PP.bOverride_FilmShoulder = true;
			PP.FilmShoulder = 0.28f;
			PP.bOverride_ExpandGamut = true;
			PP.ExpandGamut = 0.4f;
			PP.bOverride_BlueCorrection = true;
			// 0.6 is the engine default and it exists to tame OVER-saturated blues.
			// This sky is not over-saturated — measured (71,94,109), an R/B of 0.65
			// where a real clear sky is nearer 0.5 — so the default was pulling the one
			// colour in frame that should be strongest.
			PP.BlueCorrection = 0.2f;

			// --- Grade. Slightly DESATURATED overall: raw albedo through a renderer is
			// more saturated than any camera records, and pulling it back is most of
			// what separates "rendered" from "photographed". Then split-range: shadows
			// cool and very slightly lifted (they are lit by a blue sky, so this is
			// physics, not style), highlights a touch warm toward the sun.
			PP.bOverride_ColorSaturation = true;
			PP.ColorSaturation = FVector4(1.0f, 1.0f, 1.0f, 0.96f);
			PP.bOverride_ColorContrast = true;
			PP.ColorContrast = FVector4(1.0f, 1.0f, 1.0f, 1.05f);
			PP.bOverride_ColorGainShadows = true;
			PP.ColorGainShadows = FVector4(0.95f, 0.99f, 1.08f, 1.0f);
			PP.bOverride_ColorOffsetShadows = true;
			PP.ColorOffsetShadows = FVector4(0.0f, 0.002f, 0.006f, 0.0f);
			PP.bOverride_ColorGainHighlights = true;
			PP.ColorGainHighlights = FVector4(1.03f, 1.0f, 0.96f, 1.0f);

			// --- Lens. Grain is disproportionately effective against the too-clean CG
			// tell for how cheap it is; the vignette comes down from 0.35, which read as
			// an effect rather than as a lens.
			PP.bOverride_FilmGrainIntensity = true;
			PP.FilmGrainIntensity = 0.15f;
			PP.bOverride_SceneFringeIntensity = true;
			PP.SceneFringeIntensity = 0.5f;
			PP.bOverride_LensFlareIntensity = true;
			PP.LensFlareIntensity = 1.0f;
			PP.bOverride_LensFlareBokehSize = true;
			PP.LensFlareBokehSize = 3.0f;
			PP.bOverride_VignetteIntensity = true;
			PP.VignetteIntensity = 0.22f;
			PPV.Settings = PP;
		}

		SpawnActor(ABeachVolleyballCamera, FVector(0, -1400, 350), FRotator(0, 90, 0));
	}

	private void SpawnActors()
	{
		Court = Cast<ACourt>(SpawnActor(ACourt, FVector::ZeroVector, FRotator::ZeroRotator));
		SandFX = Cast<ASandFX>(SpawnActor(ASandFX, FVector::ZeroVector, FRotator::ZeroRotator));

		Ball = Cast<ABall>(SpawnActor(ABall, FVector(0, 0, 300), FRotator::ZeroRotator));
		if (Ball != nullptr)
		{
			Ball.Sand = SandFX;
			Ball.Court = Court;
			Ball.GM = this;
		}

		// Team A: back player = human-controlled (AI until gamepad input)
		HumanPawn = Cast<AHumanPlayer>(SpawnActor(AHumanPlayer, FVector(-600, 100, 90), FRotator::ZeroRotator));
		if (HumanPawn != nullptr)
		{
			HumanPawn.Sand = SandFX;
			HumanPawn.Court = Court;
			HumanPawn.GM = this;
			HumanPawn.Ball = Ball;

			// Possess so input bindings fire, then restore camera as ViewTarget
			APlayerController PC = Gameplay::GetPlayerController(0);
			if (PC != nullptr)
			{
				PC.Possess(HumanPawn);
				// Delay one frame so camera actor exists before we switch to it
				System::SetTimer(this, n"RestoreCamera", 0.05f, bLooping = false);

				// Hand the HUD its GameMode reference the same way Ball/HumanPawn
				// get theirs — there is no BlueprintCallable "get the game mode"
				// to pull it from the HUD side.
				ABeachVolleyballHUD BVHUD = Cast<ABeachVolleyballHUD>(PC.GetHUD());
				if (BVHUD != nullptr)
					BVHUD.GM = this;
			}
		}

		PlayerA2 = Cast<AAIPlayer>(SpawnActor(AAIPlayer, FVector(-150, -100, 90), FRotator::ZeroRotator));
		if (PlayerA2 != nullptr)
		{
			PlayerA2.Setup(ETeam::Team_A, EPlayerRole::Role_Front, 0.80f, Ball, SandFX, Court, this);
			// Leg-chain trace on exactly one player — see bKneeTrace. Four players
			// tracing at frame rate buries the log; one is enough to read the pose.
			// Off by default: the per-rally MOTIONSTATS knee columns cover normal
			// regression checking, and this is for digging into a specific pose.
			PlayerA2.bKneeTrace = false;
		}

		// Team B: back player deep right, front player near net right
		PlayerB1 = Cast<AAIPlayer>(SpawnActor(AAIPlayer, FVector(600, -100, 90), FRotator::ZeroRotator));
		if (PlayerB1 != nullptr)
		{
			PlayerB1.Setup(ETeam::Team_B, EPlayerRole::Role_Back, 0.75f, Ball, SandFX, Court, this);
			PlayerB1.bDebugAI = true;
			PlayerB1.bDebugHit = true;
		}

		PlayerB2 = Cast<AAIPlayer>(SpawnActor(AAIPlayer, FVector(150, 100, 90), FRotator::ZeroRotator));
		if (PlayerB2 != nullptr)
		{
			PlayerB2.Setup(ETeam::Team_B, EPlayerRole::Role_Front, 0.80f, Ball, SandFX, Court, this);
			PlayerB2.bDebugAI = true;
			PlayerB2.bDebugHit = true;
		}

		// Wire up teammates so AI can coordinate. HumanPawn is now an AAIPlayer,
		// so it pairs with PlayerA2 just like the Team B duo.
		if (PlayerA2 != nullptr && HumanPawn != nullptr) { PlayerA2.Teammate = HumanPawn; HumanPawn.Teammate = PlayerA2; }
		if (PlayerB1 != nullptr && PlayerB2 != nullptr) { PlayerB1.Teammate = PlayerB2; PlayerB2.Teammate = PlayerB1; }
	}

	private void StartMatch()
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS != nullptr)
		{
			GS.ScoreA = 0;
			GS.ScoreB = 0;
			GS.SetsWonA = 0;
			GS.SetsWonB = 0;
			GS.CurrentSet = 1;
			GS.ServingTeam = ETeam::Team_A;
			GS.GamePhase = EGamePhase::Phase_PreGame;
			GS.MatchWinner = ETeam::Team_None;
		}
		ScheduleServe();
	}

	// THE NEXT SERVE WAITS FOR THE PLAYERS, NOT A CLOCK.
	//
	// This used to be a flat 5s countdown, which meant the serve fired whether or
	// not anyone had reached their spot — and, now that someone fetches the ball,
	// often while it was still in mid-air on its way to the server. Polling
	// readiness instead lets the dead ball take exactly as long as it needs: ball
	// retrieved, everyone walked into formation, then serve.
	//
	// MinServeWait stops a point ending and the next serve starting in the same
	// breath when everyone happens to already be in position. MaxServeWait is a
	// deadlock guard, not a target: a player wedged against a clamp bound would
	// otherwise stall the match forever, and a headless verification run would
	// hang instead of failing.
	const float ServePollInterval = 0.2f;
	float MinServeWait = 1.2f;   // MatchFilmer shortens this to film more rallies
	const float MaxServeWait = 12.0f;
	private float ServeWaitTimer = 0.0f;

	private void ScheduleServe()
	{
		if (Ball == nullptr) return;
		Ball.bInPlay = false;
		ChooseFetcher();
		ServeWaitTimer = 0.0f;
		System::SetTimer(this, n"PollServeReady", ServePollInterval, bLooping = true);
	}

	UFUNCTION(BlueprintCallable)
	void PollServeReady()
	{
		ServeWaitTimer += ServePollInterval;
		if (ServeWaitTimer < MinServeWait) return;

		bool bReady = AllPlayersReady();
		if (!bReady && ServeWaitTimer < MaxServeWait) return;

		System::ClearTimer(this, "PollServeReady");
		Log("SERVEGO wait=" + int(ServeWaitTimer * 100) + " ready=" + (bReady ? 1 : 0));
		ServeBall();
	}

	private bool AllPlayersReady() const
	{
		if (HumanPawn != nullptr && !HumanPawn.IsInReadyPosition()) return false;
		if (PlayerA2  != nullptr && !PlayerA2.IsInReadyPosition())  return false;
		if (PlayerB1  != nullptr && !PlayerB1.IsInReadyPosition())  return false;
		if (PlayerB2  != nullptr && !PlayerB2.IsInReadyPosition())  return false;
		return true;
	}

	// --- Dead-ball ball retrieval ----------------------------------------
	// Between points the ball used to just sit wherever the rally ended for the
	// full ServeDelay, until RunServeSequence teleported it into the server's
	// hand. Someone walks over, picks it up and throws it to the next server
	// instead. Chosen HERE, once, rather than by each player independently:
	// two teammates each deciding "am I closest?" both run at the ball.
	AAIPlayer Fetcher;
	FVector FetchThrowTarget = FVector::ZeroVector;

	private void ChooseFetcher()
	{
		Fetcher = nullptr;
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS == nullptr || Ball == nullptr) return;

		FVector B = Ball.Position;

		// Out of everyone's reach: players are hard-clamped to their own half
		// (CourtMinX/MaxX in VolleyballPlayer.Tick), so a ball past the sidelines
		// or baselines simply cannot be walked to. Leave it and let the serve
		// snap collect it, as before.
		if (Math::Abs(B.Y) > 430.0f || Math::Abs(B.X) > 880.0f) return;

		// Whoever is about to serve walks to the serve spot, not to the ball —
		// they are the one being thrown TO. ServeBall picks the Role_Back player
		// of the serving team, so mirror that choice exactly.
		AAIPlayer NextServer = (GS.ServingTeam == ETeam::Team_A) ? Cast<AAIPlayer>(HumanPawn) : PlayerB1;
		float ServeSign = (GS.ServingTeam == ETeam::Team_A) ? -1.0f : 1.0f;
		FetchThrowTarget = FVector(ServeSign * 820.0f, 0.0f, 110.0f);

		// Only players whose half contains the ball are candidates — nobody can
		// cross the net to fetch. Of those, the closest that is not the server.
		TArray<AAIPlayer> Candidates;
		Candidates.Add(Cast<AAIPlayer>(HumanPawn));
		Candidates.Add(PlayerA2);
		Candidates.Add(PlayerB1);
		Candidates.Add(PlayerB2);

		float BestDist = 100000.0f;
		for (int i = 0; i < Candidates.Num(); i++)
		{
			AAIPlayer P = Candidates[i];
			if (P == nullptr || P == NextServer) continue;
			// Ball on my side? Team A owns X<0, Team B owns X>0.
			bool bMySide = (P.TeamSide == ETeam::Team_A) ? (B.X < 0.0f) : (B.X > 0.0f);
			if (!bMySide) continue;
			float D = (P.GetActorLocation() - B).Size2D();
			if (D < BestDist) { BestDist = D; Fetcher = P; }
		}

		if (Fetcher != nullptr)
		{
			Fetcher.BeginFetch(FetchThrowTarget);
			Log("FETCH pick=" + Fetcher.GetName()
				+ " ballX=" + int(B.X) + " ballY=" + int(B.Y)
				+ " dist=" + int(BestDist)
				+ " tgtX=" + int(FetchThrowTarget.X) + " tgtY=" + int(FetchThrowTarget.Y));
		}
		else
		{
			Log("FETCH none ballX=" + int(B.X) + " ballY=" + int(B.Y));
		}
	}

	UFUNCTION(BlueprintCallable)
	void ServeBall()
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS == nullptr || Ball == nullptr) return;

		// The serve owns the ball from here. A fetcher still mid-throw would keep
		// writing Ball.Position every frame and fight the server's carry for it.
		if (Fetcher != nullptr)
		{
			Fetcher.EndFetch();
			Fetcher = nullptr;
		}

		// Serve must clearly clear the 243cm net ~5-8m away: strong forward +
		// strong upward arc. The velocity is handed to the SERVING PLAYER, who
		// performs a real toss + overhead strike and launches the ball from the
		// strike point (see AAIPlayer.RunServeSequence). Rally bookkeeping happens
		// in OnServeLaunched at the strike moment.
		// Slightly floaty (780/700 rather than a flat rocket): the extra hang time
		// is what gives the receiver's FBIK arms time to converge on the platform —
		// rallies need the SERVE to be returnable, not an ace machine.
		//
		// Z was 640 until RunServeSequence stopped reading the strike-hand
		// position off the solved mesh bone (corruptible by whatever else was
		// blended over the arms that frame) and started reading the script's
		// own toss target instead — see ServeTossTarget in VolleyballPlayer.as.
		// That fixed a catastrophic version of this (releases as low as 66cm,
		// serve_net on ~85% of rallies), but it also means the release height
		// is now the STABLE ~145-210cm the toss target always intended, not
		// whatever the old bug happened to average out to. Measured against
		// that real, steady height: NETHIT logged the ball clearing the net by
		// only 6-24cm short at 640 (net=253, ball 229-247) on ~34% of serves —
		// a margin problem now that the target height itself is trustworthy,
		// not a repeat of the old corruption. 700 adds roughly 40cm of apex
		// (v^2/2g), comfortably covering that gap while staying a toss, not a
		// rocket.
		FVector ServeVel;
		AAIPlayer Server;
		if (GS.ServingTeam == ETeam::Team_A)
		{
			ServeVel = FVector(780, Math::RandRange(-140.0f, 140.0f), 700);
			Server = HumanPawn;
		}
		else
		{
			ServeVel = FVector(-780, Math::RandRange(-140.0f, 140.0f), 700);
			Server = PlayerB1;
		}

		if (Server != nullptr)
		{
			Server.BeginServe(ServeVel);
		}
		else
		{
			// Fallback (server missing): old direct launch so the match never stalls.
			float Sign = (GS.ServingTeam == ETeam::Team_A) ? -1.0f : 1.0f;
			Ball.Launch(FVector(Sign * 800.0f, 0, 250), ServeVel);
			OnServeLaunched();
		}
	}

	// Called by the serving player at the strike moment (ball just went live).
	void OnServeLaunched()
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS == nullptr) return;
		GS.StartRally();

		// Track the serve until it clears the net. A serve must go directly over —
		// if it hits the net or lands without crossing, it's a service fault.
		bServePhase = true;
		ServingTeamThisServe = GS.ServingTeam;

		// Fresh rally telemetry (see OnTouchForRally).
		RallyCrossings = 0;
		RallySeq = "";
	}

	// True from serve launch until the serve has crossed the net (or faulted).
	private bool bServePhase = false;
	private ETeam ServingTeamThisServe = ETeam::Team_None;

	// --- Rally telemetry -------------------------------------------------
	// The measurable definition of "they play volleyball": how many times the
	// ball crossed the net this rally, and the exact touch sequence (which team,
	// which touch number, which stroke). One RALLY line per rally at its end.
	private int RallyCrossings = 0;
	private FString RallySeq = "";

	private FString HitName(EHitType T) const
	{
		if (T == EHitType::Hit_Bump)  return "Bump";
		if (T == EHitType::Hit_Set)   return "Set";
		if (T == EHitType::Hit_Spike) return "Spike";
		if (T == EHitType::Hit_Block) return "Block";
		if (T == EHitType::Hit_Serve) return "Serve";
		return "?";
	}

	// Called by the player on every legal touch (RegisterHit).
	void OnTouchForRally(ETeam Team, int TouchNum, EHitType Type)
	{
		FString T = (Team == ETeam::Team_A) ? "A" : "B";
		RallySeq += " " + T + TouchNum + ":" + HitName(Type);
	}

	private void LogRallyEnd(FString Reason)
	{
		Log("RALLY end reason=" + Reason + " crossings=" + RallyCrossings
			+ " seq=[" + RallySeq + " ]");

		// Motion-quality totals per player, on the same hook, so every rally in a
		// headless run yields one comparable regression line per player.
		TArray<AVolleyballPlayer> MonPlayers;
		GetAllActorsOfClass(AVolleyballPlayer, MonPlayers);
		for (AVolleyballPlayer P : MonPlayers)
			if (P != nullptr) P.EmitMotionStats();

		RallyCrossings = 0;
		RallySeq = "";
	}

	// Called by the ball when it crosses the net plane, so we know the serve was good.
	UFUNCTION(BlueprintCallable)
	void OnBallCrossedNet()
	{
		bServePhase = false;
		RallyCrossings++;
	}

	UFUNCTION(BlueprintCallable)
	void OnBallHitFloor(FVector HitPos)
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS == nullptr) return;
		if (GS.GamePhase != EGamePhase::Phase_Rally) return;

		ETeam ScoringTeam;
		if (bServePhase)
		{
			// Ball landed while still a serve = it never cleared the net = fault.
			// Point to the receiving team regardless of which side it landed on.
			bServePhase = false;
			ScoringTeam = (ServingTeamThisServe == ETeam::Team_A) ? ETeam::Team_B : ETeam::Team_A;
			LogRallyEnd("serve_fault_floor");
		}
		else if (HitPos.X < 0)
		{
			ScoringTeam = ETeam::Team_B;
			LogRallyEnd("floor_A x=" + int(HitPos.X) + " y=" + int(HitPos.Y));
		}
		else
		{
			ScoringTeam = ETeam::Team_A;
			LogRallyEnd("floor_B x=" + int(HitPos.X) + " y=" + int(HitPos.Y));
		}

		GS.AddPoint(ScoringTeam);

		if (GS.GamePhase == EGamePhase::Phase_MatchOver)
		{
			if (Ball != nullptr)
				Ball.StartRestartCountdown(MatchRestartDelay);
		}
		else
		{
			ScheduleServe();
		}
	}

	UFUNCTION(BlueprintCallable)
	void OnBallHitNet()
	{
		// A serve that hits the net is a service fault — point to the receiving team.
		if (!bServePhase) return;
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS == nullptr || GS.GamePhase != EGamePhase::Phase_Rally) return;

		bServePhase = false;
		ETeam Receiver = (ServingTeamThisServe == ETeam::Team_A) ? ETeam::Team_B : ETeam::Team_A;
		LogRallyEnd("serve_net");
		GS.AddPoint(Receiver);
		ScheduleServe();
	}

	UFUNCTION(BlueprintCallable)
	void OnTouchViolation(ETeam FaultingTeam)
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS == nullptr) return;

		LogRallyEnd((FaultingTeam == ETeam::Team_A) ? "touches_A" : "touches_B");
		ETeam ScoringTeam = (FaultingTeam == ETeam::Team_A) ? ETeam::Team_B : ETeam::Team_A;
		GS.AddPoint(ScoringTeam);
		ScheduleServe();
	}

	UFUNCTION(BlueprintCallable)
	void ResetMatch()
	{
		StartMatch();
	}

	UFUNCTION()
	void RestoreCamera()
	{
		APlayerController PC = Gameplay::GetPlayerController(0);
		if (PC == nullptr) return;
		TArray<AActor> Found;
		GetAllActorsOfClass(ABeachVolleyballCamera, Found);
		if (Found.Num() > 0)
			PC.SetViewTargetWithBlend(Found[0], 0.0f);
	}
}
