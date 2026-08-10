enum CoachScrollTarget: Hashable {
  case top
  case bottom
}

enum CoachScrollTrigger: Equatable {
  case initialAppearance
  case sessionReset
  case foregroundActivation
  case reviewPeriodChanged
  case messageCountChanged(previous: Int, current: Int)
  case proposalCountChanged(previous: Int, current: Int)
  case reviewBecameAvailable
  case loadingStarted
  case loadingFinished
  case warningCountChanged(previous: Int, current: Int)
}

enum CoachScrollPolicy {
  static func target(
    for trigger: CoachScrollTrigger,
    isFollowingGeneratedContent: Bool = true
  ) -> CoachScrollTarget? {
    switch trigger {
    case .initialAppearance,
         .sessionReset,
         .foregroundActivation,
         .reviewPeriodChanged:
      return .top
    case let .messageCountChanged(previous, current),
         let .proposalCountChanged(previous, current),
         let .warningCountChanged(previous, current):
      guard isFollowingGeneratedContent, current > previous else {
        return nil
      }
      return .bottom
    case .reviewBecameAvailable, .loadingStarted:
      return isFollowingGeneratedContent ? .bottom : nil
    case .loadingFinished:
      return nil
    }
  }
}
