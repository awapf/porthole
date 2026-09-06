import Foundation

public enum Porthole {
    /// Semantic version of this build.
    ///
    /// Checked in rather than derived from `git describe`, because release
    /// tarballs — which is how Homebrew builds it — carry no git metadata.
    /// `make tag VERSION=x.y.z` keeps this in step with the tag.
    public static let version = "0.1.1"

    public static var versionString: String {
        "porthole \(version)"
    }
}
