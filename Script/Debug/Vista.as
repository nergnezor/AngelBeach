// Vista — the LOCKED VISUAL REFERENCE SERIES.
//
// PhotoBooth judges POSES and MatchFilmer judges MOTION. Neither can judge the
// PICTURE: both move their camera to follow what the player is doing, so no two
// runs frame the same pixels and a before/after on lighting or materials is
// guesswork.
//
// Vista fixes that by removing every variable except the one under test. It
// inherits the REAL ABeachVolleyballGameMode — same sun, same sky, same post
// process, same court, same four players — then freezes the match and walks a
// camera through a fixed list of world-space setups. Same framing, forever.
// Every visual change in the fidelity pass is a before/after on these shots.
//
//   UnrealEditor BeachVolleyball.uproject "/Game/CourtLevel?game=/Script/Angelscript.VistaGameMode" \
//       -game -RenderOffscreen -resx=1280 -resy=720 -nosplash -unattended -asdebugport=59999
//
// Then measure, don't squint:  python3 scripts/shot_stats.py
//
// WHY WORLD SPACE, NOT ACTOR SPACE. PhotoBooth's cameras are offsets from the
// dummy's feet, which is right for pose reading — the camera should follow the
// subject. Here the subject IS the frame, so every position is an absolute world
// coordinate and the players are parked on fixed marks instead.
struct FVistaShot
{
	FString Name;
	FVector Pos;
	FVector Look;
	FString Note;
}

class AVistaGameMode : ABeachVolleyballGameMode
{
	// Engine base HUD: no score overlay burned into the reference images.
	default HUDClass = AHUD;

	private TArray<FVistaShot> Shots;
	private AActor CamActor;
	private int ShotIdx = 0;
	// 0 = camera moved, waiting for the image to converge; 1 = shot fired, holding
	// still. HighResShot captures several frames AFTER the console command, so the
	// camera must not move during the hold or every PNG shows the next setup.
	private int Phase = 0;
	private float PhaseTimer = 0.0f;
	// Longer than PhotoBooth's 0.6: this scene has Lumen GI and a real-time sky
	// light capture, and TSR needs a clean history before the pixels are worth
	// measuring. A shot taken mid-convergence measures noise, not the change.
	const float CamSettle = 1.2f;
	const float ShotHold = 0.6f;
	private bool bDone = false;

	// Where the ball is parked. Chosen to sit in Team A's half, clear of the net,
	// at roughly contact height so the "ball" shot reads as a ball in play.
	const FVector BallMark = FVector(-450, 200, 120);

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		Super::BeginPlay();

		// Kill the serve poll. StartMatch() scheduled it; left running, a serve
		// fires mid-series and the players scatter.
		System::ClearTimer(this, "PollServeReady");

		BuildShotList();
		CamActor = SpawnActor(ACameraActor, Shots[0].Pos, FRotator::ZeroRotator);
		System::SetTimer(this, n"AttachCamera", 0.1f, bLooping = false);
	}

	private void BuildShotList()
	{
		FVistaShot S;

		// 1. THE shot. Identical to the live match camera (Camera.as CamPos/LookAt),
		//    so this is literally what the player sees. Every framing decision —
		//    FOV, height, distance — is judged here first.
		S.Name = "wide";     S.Pos = FVector(-1050, 0, 560);  S.Look = FVector(0, 0, 140);
		S.Note = "gameplay framing: court, net, sky, all four players";
		Shots.Add(S);

		// 2. Two-shot at conversational distance: the figures large enough that skin,
		//    shading and silhouette are readable, but still in their environment.
		S.Name = "two_shot"; S.Pos = FVector(-560, 300, 210);  S.Look = FVector(-280, -30, 115);
		S.Note = "figures at readable size, lit side and shadow side both in frame";
		Shots.Add(S);

		// 3. The ball, close. It is the object the camera follows in every frame of
		//    the real game, and today it is a flat HDR-yellow sphere.
		// Re-aimed once: the first placement put a player directly behind the ball
		// along the view ray, so the subject of the shot was read against a body
		// instead of against sand. Clear sand behind it now.
		S.Name = "ball";     S.Pos = FVector(-565, 272, 162);  S.Look = BallMark;
		S.Note = "ball at ~130cm: panel seams, shading gradient, silhouette tessellation";
		Shots.Add(S);

		// 4. Sand at a grazing angle. Micro-normal, sparkle and crater relief only
		//    show at low incidence — a top-down shot of sand shows nothing at all.
		S.Name = "sand";     S.Pos = FVector(-520, 330, 24);   S.Look = FVector(250, -140, 12);
		S.Note = "grazing sand: micro-normal, sparkle, footprint/crater relief";
		Shots.Add(S);

		// 5. Sea and sky with no court in frame. This is where the 40-band dome
		//    staircase lives, and where a real horizon has to appear.
		// X=-700 keeps the net POST out of frame — the posts stand on the net line
		// at X=0, and the first take had one dead centre.
		S.Name = "horizon";  S.Pos = FVector(-700, -240, 190); S.Look = FVector(-700, -3000, 300);
		S.Note = "shoreline, sea, sky gradient — the dome banding shows here";
		Shots.Add(S);

		// 6. Head and shoulders of Team A's front player, parked on its mark.
		S.Name = "skin";     S.Pos = FVector(-262, -42, 152);  S.Look = FVector(-152, -98, 142);
		S.Note = "head/shoulders at ~125cm: skin response, material, self-shadow";
		Shots.Add(S);
	}

	UFUNCTION()
	void AttachCamera()
	{
		APlayerController PC = Gameplay::GetPlayerController(0);
		if (PC != nullptr && CamActor != nullptr)
			PC.SetViewTargetWithBlend(CamActor, 0.0f);
		MoveCam(0);
	}

	// Park every moving thing on its mark, every frame. The AI still runs and still
	// wants to walk somewhere; snapping after it has moved is what keeps the series
	// reproducible without having to disable the AI (which would also disable the
	// idle pose that makes the bodies look like bodies).
	private void FreezeScene()
	{
		if (Ball != nullptr)
		{
			Ball.bInPlay = false;
			Ball.BallVel = FVector::ZeroVector;
			Ball.Position = BallMark;
			Ball.SetActorLocation(BallMark);
		}
		Park(HumanPawn, FVector(-600, 100, 90),  FVector(1, 0, 0));
		Park(PlayerA2,  FVector(-150, -100, 90), FVector(1, 0, 0));
		Park(PlayerB1,  FVector(600, -100, 90),  FVector(-1, 0, 0));
		Park(PlayerB2,  FVector(150, 100, 90),   FVector(-1, 0, 0));
	}

	private void Park(AVolleyballPlayer P, FVector Mark, FVector Facing)
	{
		if (P == nullptr) return;
		P.PlayerVelocity = FVector::ZeroVector;
		P.SetActorLocation(Mark);
		P.FacingDir = Facing;
		P.bHasFacing = true;
	}

	UFUNCTION(BlueprintOverride)
	void Tick(float DeltaSeconds)
	{
		if (bDone) return;
		FreezeScene();
		if (ShotIdx >= Shots.Num()) return;

		PhaseTimer += DeltaSeconds;
		if (Phase == 0)
		{
			if (PhaseTimer < CamSettle) return;
			Shoot();
			Phase = 1;
			PhaseTimer = 0.0f;
		}
		else if (PhaseTimer >= ShotHold)
		{
			ShotIdx++;
			Phase = 0;
			PhaseTimer = 0.0f;
			if (ShotIdx < Shots.Num())
			{
				MoveCam(ShotIdx);
			}
			else
			{
				bDone = true;
				Log("VISTA done — quitting");
				System::SetTimer(this, n"QuitVista", 1.5f, bLooping = false);
			}
		}
	}

	private void MoveCam(int Idx)
	{
		if (CamActor == nullptr || Idx >= Shots.Num()) return;
		FVistaShot S = Shots[Idx];
		CamActor.SetActorLocation(S.Pos);
		CamActor.SetActorRotation((S.Look - S.Pos).GetSafeNormal().Rotation());
	}

	private void Shoot()
	{
		FVistaShot S = Shots[ShotIdx];
		FString ShotName = "Vista_" + (ShotIdx + 1) + "_" + S.Name;
		System::ExecuteConsoleCommand("HighResShot 1280x720 filename=" + ShotName);
		// Ground truth alongside the image, same contract as BOOTH/FILM lines.
		Log("VISTA shot=" + ShotName
			+ " camPos=(" + int(S.Pos.X) + "," + int(S.Pos.Y) + "," + int(S.Pos.Z) + ")"
			+ " lookAt=(" + int(S.Look.X) + "," + int(S.Look.Y) + "," + int(S.Look.Z) + ")"
			+ " — " + S.Note);
	}

	UFUNCTION()
	void QuitVista()
	{
		System::ExecuteConsoleCommand("quit");
	}
}
