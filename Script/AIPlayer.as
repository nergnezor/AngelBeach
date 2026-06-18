// AI player - volleyball state machine: Receive -> Set -> Attack with proper
// roles, height-aware contacts, and team coordination (no flip-flopping).

enum EPlayerRole { Role_Back, Role_Front }

class AAIPlayer : AVolleyballPlayer
{
	UPROPERTY(BlueprintReadWrite) float Difficulty = 0.75f;
	UPROPERTY(BlueprintReadWrite) EPlayerRole Role = EPlayerRole::Role_Back;
	UPROPERTY() ABall Ball;
	UPROPERTY() AAIPlayer Teammate;  // the other player on this team

	float ReactionDelay = 0.0f;
	float ReactionTimer = 0.0f;

	// True if I made my team's most recent contact — so my teammate takes the
	// next touch (digger != setter != attacker), preventing one player from
	// making all three touches and committing a fourth-touch fault.
	bool bIMadeLastTouch = false;

	// --- Contact-height windows (relative to ball Z) ---
	// Dig:   ball low, near waist/chest      -> bump it up
	// Set:   ball at chest/head height       -> soft high arc
	// Spike: ball above head while airborne  -> drive it down
	const float DigMaxZ   = 130.0f;   // ball below this = dig
	const float SetMinZ   = 110.0f;
	const float SetMaxZ   = 220.0f;
	const float SpikeMinZ = 200.0f;   // need a jump to reach

	void Setup(ETeam Team, EPlayerRole InRole, float InDifficulty,
		ABall InBall, ASandFX InSand, ACourt InCourt, ABeachVolleyballGameMode InGM)
	{
		TeamSide = Team;
		Role = InRole;
		Difficulty = InDifficulty;
		Ball = InBall;
		Sand = InSand;
		Court = InCourt;
		GM = InGM;
		MoveSpeed = 420.0f + Difficulty * 220.0f;
		ReactionDelay = Math::Lerp(0.35f, 0.04f, Difficulty);

		CourtMinY = -450.0f;
		CourtMaxY = 450.0f;
		if (Team == ETeam::Team_A) { CourtMinX = -900.0f; CourtMaxX = -5.0f; }
		else                       { CourtMinX =    5.0f; CourtMaxX = 900.0f; }
	}

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		InitPlayer();
		CourtMinX = -900.0f; CourtMaxX = -5.0f;
		CourtMinY = -450.0f; CourtMaxY = 450.0f;
	}

	UFUNCTION(BlueprintOverride)
	void Tick(float DeltaTime)
	{
		UpdatePlayer(DeltaTime);
		if (Ball == nullptr) FindBall();
		if (Ball == nullptr || !Ball.bInPlay) return;

		ReactionTimer += DeltaTime;
		if (ReactionTimer < ReactionDelay) return;
		ReactionTimer = 0.0f;

		UpdateAI(DeltaTime);
	}

	// ---------------------------------------------------------------
	// Main decision loop (protected so AHumanPlayer can reuse it as its
	// AI fallback when no gamepad input is active)
	// ---------------------------------------------------------------
	protected void UpdateAI(float DeltaTime)
	{
		// Ball is on the opponent's side: hold defensive ready position and clear
		// our touch-ownership so the next receive starts fresh.
		if (!IsBallComingToMySide())
		{
			bIMadeLastTouch = false;
			if (bDebugAI) Log(DebugTag() + " DEFEND ballX=" + int(Ball.Position.X) + " ballZ=" + int(Ball.Position.Z));
			MoveToward2D(DefendPos(), DeltaTime);
			return;
		}

		int Touches = TeamTouches();          // how many times WE have touched it
		FVector Landing = Ball.PredictLanding();

		// Decide my job for this contact based on touch count + role
		if (AmIHitter(Landing))
		{
			if (bDebugAI) Log(DebugTag() + " HITTER t=" + Touches + " ballZ=" + int(Ball.Position.Z) + " grounded=" + bIsGrounded);
			PlayHitter(Touches, Landing, DeltaTime);
		}
		else
		{
			if (bDebugAI) Log(DebugTag() + " SUPPORT t=" + Touches);
			PlaySupport(Landing, DeltaTime);
		}
	}

	// Temporary diagnostics — set true on ONE player from GameMode to inspect.
	bool bDebugAI = false;
	private FString DebugTag() const
	{
		FString T = (TeamSide == ETeam::Team_A) ? "A" : "B";
		FString R = (Role == EPlayerRole::Role_Front) ? "Front" : "Back";
		return T + "/" + R;
	}

	// ---------------------------------------------------------------
	// Role assignment — deterministic so the two players never swap
	// mid-rally and end up chasing the same ball.
	// ---------------------------------------------------------------
	private bool AmIHitter(FVector Landing) const
	{
		if (Teammate == nullptr) return true;

		// I never take two contacts in a row — if I made the last touch, it's
		// my teammate's turn now. This guarantees digger != setter != attacker.
		if (bIMadeLastTouch) return false;
		if (Teammate.bIMadeLastTouch) return true;

		// Fresh ball coming over (no team touches yet): closest player digs,
		// with the back player favored for deep balls (typical serve receive).
		float MyDist    = (GetActorLocation() - Landing).Size2D();
		float TheirDist = (Teammate.GetActorLocation() - Landing).Size2D();

		bool bDeep = IsDeep(Landing.X);
		if (bDeep && Role == EPlayerRole::Role_Back)  return true;
		if (bDeep && Role == EPlayerRole::Role_Front) return false;

		return MyDist <= TheirDist;
	}

	// ---------------------------------------------------------------
	// I am the player who will contact the ball this touch
	// ---------------------------------------------------------------
	private void PlayHitter(int Touches, FVector Landing, float DeltaTime)
	{
		float BallZ = Ball.Position.Z;

		if (Touches >= 2)
		{
			// ATTACK: get under a high ball, jump, and spike at the peak
			ApproachForSpike(DeltaTime);
			return;
		}

		// RECEIVE (touch 0) or SET (touch 1): move under the landing spot
		FVector Goal = ClampToCourt(Landing);
		MoveToward2D(Goal, DeltaTime);

		if (!IsWithinReach()) return;

		if (Touches == 0)
		{
			// Dig only when the ball has dropped to a reachable height
			if (BallZ <= DigMaxZ + PlayerHeight)
				DoDig();
		}
		else // Touches == 1
		{
			// Set when ball is around chest/head height
			if (BallZ >= SetMinZ && BallZ <= SetMaxZ + PlayerHeight)
				DoSet();
		}
	}

	// ---------------------------------------------------------------
	// I am NOT contacting this touch — get to the right support spot
	// ---------------------------------------------------------------
	private void PlaySupport(FVector Landing, float DeltaTime)
	{
		MoveToward2D(SupportPos(Landing), DeltaTime);
	}

	// ---------------------------------------------------------------
	// Spike approach: time the jump so contact happens at the top
	// ---------------------------------------------------------------
	private void ApproachForSpike(float DeltaTime)
	{
		// Stand just behind the net under the ball's current X, ready to swing
		FVector UnderBall = FVector(Ball.Position.X, Ball.Position.Y, FloorZ + PlayerHeight);
		UnderBall = ClampToCourt(UnderBall);
		MoveToward2D(UnderBall, DeltaTime);

		float Horiz = (GetActorLocation() - FVector(Ball.Position.X, Ball.Position.Y, 0)).Size2D();
		float BallZ = Ball.Position.Z;

		// Jump when the ball is high, descending into strike range, and we're under it
		if (bIsGrounded && Horiz < 130.0f && BallZ > SpikeMinZ && Ball.BallVel.Z < 120.0f)
			Jump();

		// Spike at contact: airborne and ball within arm's reach above head
		if (!bIsGrounded && IsWithinReach() && BallZ > PlayerHeight + 120.0f)
			DoSpike();
		else if (bIsGrounded && IsWithinReach() && BallZ <= SpikeMinZ)
			DoSet();   // ball came in low — recover with a controlled set over
	}

	// ---------------------------------------------------------------
	// Contacts — the ball now physically bounces off the player. These set the
	// AIM target so OnBallContact (on the base player) knows where to send it.
	// ---------------------------------------------------------------
	private void DoDig()
	{
		// Aim the bump up toward where the setter wants it (near our net, center)
		float Sign = MySign();
		AimAt(FVector(Sign * 180.0f, 0.0f, 260.0f));
	}

	private void DoSet()
	{
		// Aim a high arc to the attacker's position at the net
		float Sign = MySign();
		FVector AttackSpot = (Teammate != nullptr && Teammate.Role == EPlayerRole::Role_Front)
			? Teammate.GetActorLocation()
			: FVector(Sign * 150.0f, Ball.Position.Y * 0.4f, FloorZ + PlayerHeight);
		AimAt(AttackSpot + FVector(Sign * 20.0f, 0, 320.0f));
	}

	private void DoSpike()
	{
		// Aim down into the opponent's open court; OnBallContact forces the angle.
		AimAt(PickAttackTarget());
	}

	// Tell the base player where to send the ball on the next physical contact.
	private void AimAt(FVector WorldTarget)
	{
		DesiredAim = WorldTarget;
		bHasAim = true;
	}

	// Aim for the opponent's open court, away from their players
	private FVector PickAttackTarget() const
	{
		float OppSign = -MySign();
		float TargetX = OppSign * Math::Lerp(350.0f, 700.0f, Difficulty);

		// Aim to whichever Y half is less defended — approximate by aiming
		// opposite our own attacker's Y, with error that shrinks with skill
		float AimY = (GetActorLocation().Y > 0) ? -250.0f : 250.0f;
		float Error = Math::RandRange(-180.0f, 180.0f) * (1.0f - Difficulty);
		AimY = Math::Clamp(AimY + Error, CourtMinY + 60.0f, CourtMaxY - 60.0f);

		return FVector(TargetX, AimY, FloorZ + BallRadiusGuess());
	}

	private float BallRadiusGuess() const { return (Ball != nullptr) ? Ball.BallRadius : 10.5f; }

	// ---------------------------------------------------------------
	// Positioning helpers
	// ---------------------------------------------------------------
	private FVector SupportPos(FVector Landing) const
	{
		float Sign = MySign();
		if (Role == EPlayerRole::Role_Front)
		{
			// Front player: stay at net ready to attack, track ball Y
			float Y = Math::Clamp(Landing.Y, CourtMinY + 100.0f, CourtMaxY - 100.0f);
			return FVector(Sign * 170.0f, Y, FloorZ + PlayerHeight);
		}
		else
		{
			// Back player: cover deep court behind the attacker
			float Y = Math::Clamp(Landing.Y * 0.5f, CourtMinY + 100.0f, CourtMaxY - 100.0f);
			return FVector(Sign * 620.0f, Y, FloorZ + PlayerHeight);
		}
	}

	// Defensive ready position while the ball is on the other side. Hold a
	// stable spot (each player covers half the court in Y) rather than chasing
	// the ball's Y every frame — that was causing constant side-to-side running.
	private FVector DefendPos() const
	{
		float Sign = MySign();
		float X = (Role == EPlayerRole::Role_Front) ? Sign * 220.0f : Sign * 640.0f;
		// Front covers one Y half, back the other, for simple court coverage.
		float Y = (Role == EPlayerRole::Role_Front) ? -150.0f : 150.0f;
		return FVector(X, Y, FloorZ + PlayerHeight);
	}

	// ---------------------------------------------------------------
	// Queries
	// ---------------------------------------------------------------
	private float MySign() const { return (TeamSide == ETeam::Team_A) ? -1.0f : 1.0f; }

	private int TeamTouches() const
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS == nullptr) return 0;
		// Only count touches that belong to our team this rally
		if (GS.LastTouchTeam == TeamSide) return GS.TouchesThisRally;
		return 0;  // ball just crossed to us — this is our receive (touch 0)
	}

	// Should our team actively go play the ball right now? Only when the ball is
	// genuinely on our side of the net — not while it's still high over the
	// opponent's court (even if it's predicted to eventually cross to us).
	private bool IsBallComingToMySide() const
	{
		bool bBallOnMySide = (TeamSide == ETeam::Team_A) ? Ball.Position.X <= 0.0f
		                                                 : Ball.Position.X >= 0.0f;

		// If the ball is physically on our side, it's ours to play.
		if (bBallOnMySide) return true;

		// Ball is on the opponent's side. Only commit early if it has clearly
		// crossed toward us (moving to our side AND already low enough that the
		// predicted landing is on our court) — otherwise hold and defend.
		bool bMovingToMe = (TeamSide == ETeam::Team_A) ? Ball.BallVel.X < -50.0f
		                                               : Ball.BallVel.X >  50.0f;
		if (!bMovingToMe) return false;

		FVector Landing = Ball.PredictLanding();
		bool bLandMine = (TeamSide == ETeam::Team_A) ? Landing.X <= 0.0f
		                                             : Landing.X >= 0.0f;
		// Require the ball to be near or past the net before charging in.
		bool bNearNet = Math::Abs(Ball.Position.X) < 250.0f;
		return bLandMine && bNearNet;
	}

	private bool IsDeep(float X) const
	{
		if (TeamSide == ETeam::Team_A) return X < -350.0f;
		return X > 350.0f;
	}

	// Horizontal reach to the ball's current position
	private bool IsWithinReach() const
	{
		FVector ToBall = Ball.Position - GetActorLocation();
		return ToBall.Size2D() < 110.0f;
	}

	private FVector ClampToCourt(FVector P) const
	{
		return FVector(
			Math::Clamp(P.X, CourtMinX + 40.0f, CourtMaxX - 40.0f),
			Math::Clamp(P.Y, CourtMinY + 40.0f, CourtMaxY - 40.0f),
			FloorZ + PlayerHeight);
	}

	// ---------------------------------------------------------------
	// Movement (no auto-jump here — jumping is decided by spike logic)
	// ---------------------------------------------------------------
	private void MoveToward2D(FVector Target, float Dt)
	{
		FVector Dir = Target - GetActorLocation();
		Dir.Z = 0;
		if (Dir.Size2D() > 8.0f)
			MovePlayer(FVector2D(Dir.GetSafeNormal2D().X, Dir.GetSafeNormal2D().Y));
		else
			MovePlayer(FVector2D::ZeroVector);
	}

	// ---------------------------------------------------------------
	// The base player registers the touch when the ball physically bounces off
	// us; we just record that it was us, so the teammate takes the next contact.
	void OnTouchRegistered() override
	{
		bIMadeLastTouch = true;
		if (Teammate != nullptr)
			Teammate.bIMadeLastTouch = false;
	}

	protected void FindBall()
	{
		TArray<AActor> Found;
		GetAllActorsOfClass(ABall, Found);
		if (Found.Num() > 0)
			Ball = Cast<ABall>(Found[0]);
	}
}
