// AI player - trajectory prediction, coordinated team play

enum EAIState { AI_Idle, AI_Positioning, AI_Approach, AI_Hitting }
enum EPlayerRole { Role_Back, Role_Front }

class AAIPlayer : AVolleyballPlayer
{
	UPROPERTY(BlueprintReadWrite) float Difficulty = 0.75f;
	UPROPERTY(BlueprintReadWrite) EPlayerRole Role = EPlayerRole::Role_Back;
	UPROPERTY() ABall Ball;
	UPROPERTY() AAIPlayer Teammate;  // the other player on this team

	float ReactionDelay = 0.0f;
	float ReactionTimer = 0.0f;

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
		MoveSpeed = 400.0f + Difficulty * 200.0f;
		ReactionDelay = Math::Lerp(0.5f, 0.05f, Difficulty);

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

	private void UpdateAI(float DeltaTime)
	{
		FVector BallLoc = Ball.GetActorLocation();
		FVector MyLoc   = GetActorLocation();
		bool bMySide    = IsOnMySide(BallLoc.X);

		if (!bMySide)
		{
			MoveToward(ReadyPos(), DeltaTime);
			return;
		}

		// Predict where the ball will be when we could reach it
		float TimeToReach = EstimateTimeToReach();
		FVector LandPos   = PredictBall(TimeToReach);

		// Am I the closest teammate to the ball?
		bool bIAmClosest = IAmClosestToBall();

		if (bIAmClosest)
		{
			// Chase the predicted landing spot
			FVector Goal = FVector(
				Math::Clamp(LandPos.X, CourtMinX + 40.0f, CourtMaxX - 40.0f),
				Math::Clamp(LandPos.Y, CourtMinY + 40.0f, CourtMaxY - 40.0f),
				FloorZ + PlayerHeight);
			MoveToward(Goal, DeltaTime);

			if (IsNearBall(Ball))
				DecideHit();
		}
		else
		{
			// I'm the support player — move to ideal support position
			MoveToward(SupportPos(LandPos), DeltaTime);
		}
	}

	// Where should I be when NOT hitting?
	private FVector SupportPos(FVector BallLandPos) const
	{
		float Sign = (TeamSide == ETeam::Team_A) ? -1.0f : 1.0f;
		if (Role == EPlayerRole::Role_Front)
		{
			// Front player: stay near net, track ball Y, ready to attack
			float NetX = Sign * 160.0f;
			float Y = Math::Clamp(BallLandPos.Y, CourtMinY + 100.0f, CourtMaxY - 100.0f);
			return FVector(NetX, Y, FloorZ + PlayerHeight);
		}
		else
		{
			// Back player: hold deep cover position
			float DeepX = Sign * 650.0f;
			float Y = Math::Clamp(BallLandPos.Y * 0.5f, CourtMinY + 100.0f, CourtMaxY - 100.0f);
			return FVector(DeepX, Y, FloorZ + PlayerHeight);
		}
	}

	private FVector ReadyPos() const
	{
		float Sign = (TeamSide == ETeam::Team_A) ? -1.0f : 1.0f;
		float X = (Role == EPlayerRole::Role_Front) ? Sign * 200.0f : Sign * 650.0f;
		return FVector(X, 0, FloorZ + PlayerHeight);
	}

	private void DecideHit()
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		int Touches = (GS != nullptr) ? GS.TouchesThisRally : 0;

		FVector BallLoc = Ball.GetActorLocation();
		float Sign = (TeamSide == ETeam::Team_A) ? 1.0f : -1.0f;

		if (Touches == 0 || (Role == EPlayerRole::Role_Back && Touches <= 1 && !IsTeammateFront()))
		{
			// Dig/receive: lift the ball up toward our front player
			FVector FrontPos = (Teammate != nullptr)
				? Teammate.GetActorLocation()
				: FVector(Sign * 200.0f, 0, FloorZ + PlayerHeight);
			FVector ToFront = (FrontPos - BallLoc + FVector(0, 0, 200.0f)).GetSafeNormal();
			HitToward(ToFront, 550.0f);
		}
		else if (Touches == 1)
		{
			// Set: high arc to front player for attack
			FVector AttackPos = (Teammate != nullptr && Teammate.Role == EPlayerRole::Role_Front)
				? Teammate.GetActorLocation()
				: FVector(Sign * 150.0f, BallLoc.Y * 0.3f, FloorZ + PlayerHeight);
			// Aim high above the target so the front player can jump-attack
			FVector SetTarget = AttackPos + FVector(0, 0, 250.0f);
			FVector ToSet = (SetTarget - BallLoc).GetSafeNormal();
			HitToward(ToSet, 620.0f);
		}
		else
		{
			// Spike or attack: aim toward opponent's open court
			FVector AimPos = PickAttackTarget();
			FVector ToAim  = (AimPos - BallLoc).GetSafeNormal();
			float Speed    = (Difficulty > 0.6f) ? 1400.0f : 1000.0f;
			HitToward(ToAim, Speed);
		}
	}

	// Pick a spot in the opponent's court to aim for (away from where they are)
	private FVector PickAttackTarget() const
	{
		float OppSign = (TeamSide == ETeam::Team_A) ? 1.0f : -1.0f;

		if (Teammate != nullptr)
		{
			// Aim away from opponent cluster — simplified: aim opposite Y side
			float TeammateY = GetActorLocation().Y;
			float AimY = (TeammateY > 0) ? -280.0f : 280.0f;
			return FVector(OppSign * 600.0f, AimY, 0);
		}
		return FVector(OppSign * 500.0f, Math::RandRange(-200.0f, 200.0f) * (1.0f - Difficulty), 0);
	}

	private void HitToward(FVector Dir, float Speed)
	{
		Ball.HitBall(Dir, Speed);
		TriggerReach(Dir);
		RegisterHitBall();
	}

	private void RegisterHitBall()
	{
		bCanHit = false;
		HitTimer = 0;
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS != nullptr)
		{
			bool bValid = GS.RegisterTouch(TeamSide);
			if (!bValid && GM != nullptr)
				GM.OnTouchViolation(TeamSide);
		}
	}

	private bool IsTeammateFront() const
	{
		return Teammate != nullptr && Teammate.Role == EPlayerRole::Role_Front;
	}

	private bool IAmClosestToBall() const
	{
		if (Teammate == nullptr) return true;
		FVector BallLoc  = Ball.GetActorLocation();
		float MyDist     = (GetActorLocation() - BallLoc).Size2D();
		float TheirDist  = (Teammate.GetActorLocation() - BallLoc).Size2D();
		// Front player defers to back player on first touch when ball is deep
		if (Role == EPlayerRole::Role_Front)
		{
			ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
			int Touches = (GS != nullptr) ? GS.TouchesThisRally : 0;
			bool bBallIsDeep = IsOnDeepSide(Ball.Position.X);
			if (Touches == 0 && bBallIsDeep) return false;
		}
		return MyDist <= TheirDist;
	}

	private bool IsOnDeepSide(float BallX) const
	{
		if (TeamSide == ETeam::Team_A) return BallX < -350.0f;
		return BallX > 350.0f;
	}

	private bool IsOnMySide(float BallX) const
	{
		return (TeamSide == ETeam::Team_A) ? BallX <= 0.0f : BallX >= 0.0f;
	}

	// How long until I could intercept the ball (rough estimate in seconds)
	private float EstimateTimeToReach() const
	{
		FVector BallLoc = Ball.GetActorLocation();
		float Dist = (GetActorLocation() - BallLoc).Size2D();
		float Speed = Math::Max(MoveSpeed, 1.0f);
		return Math::Clamp(Dist / Speed, 0.1f, 1.5f);
	}

	private void MoveToward(FVector Target, float Dt)
	{
		FVector Dir = Target - GetActorLocation();
		Dir.Z = 0;
		float Dist = Dir.Size2D();

		if (Dist > 8.0f)
			MovePlayer(FVector2D(Dir.GetSafeNormal2D().X, Dir.GetSafeNormal2D().Y));
		else
			MovePlayer(FVector2D::ZeroVector);

		// Jump only when close to ball AND ball is above head height AND moving upward
		if (Ball != nullptr && bIsGrounded && IsNearBall(Ball))
		{
			FVector BallLoc = Ball.GetActorLocation();
			bool bBallHigh = BallLoc.Z > PlayerHeight * 2.2f;
			bool bBallRising = Ball.BallVel.Z > 0;
			if (bBallHigh && bBallRising)
				Jump();
		}
	}

	private FVector PredictBall(float TimeAhead) const
	{
		FVector PPos = Ball.Position;
		FVector PVel = Ball.BallVel;
		float Dt = 0.033f;
		float T = 0;
		while (T < TimeAhead)
		{
			PVel.Z += Ball.Gravity * Dt;
			PPos   += PVel * Dt;
			T      += Dt;
			if (PPos.Z <= Ball.FloorZ + Ball.BallRadius)
			{
				PPos.Z = Ball.FloorZ + Ball.BallRadius;
				break;
			}
		}
		return PPos;
	}

	private void FindBall()
	{
		TArray<AActor> Found;
		GetAllActorsOfClass(ABall, Found);
		if (Found.Num() > 0)
			Ball = Cast<ABall>(Found[0]);
	}
}
