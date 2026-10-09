class Hc < Formula
  desc "Herdr lifecycle-aware command wrapper"
  homepage "https://github.com/takumi3488/hc"
  version "0.1.2"

  on_macos do
    on_arm do
      url "https://github.com/takumi3488/hc/releases/download/v0.1.2/hc-aarch64-macos-none.tar.gz"
      sha256 "c01137ffbeba30484cd526bb17c2ca73066a0ec6dfdf388a983709bdbc62d1cd"
    end
    on_intel do
      url "https://github.com/takumi3488/hc/releases/download/v0.1.2/hc-x86_64-macos-none.tar.gz"
      sha256 "62dda8bde28c7ae1b5eaa7bdce865502a7f2ec2767eeefe95eb25a88460f3a7a"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/takumi3488/hc/releases/download/v0.1.2/hc-aarch64-linux-musl.tar.gz"
      sha256 "d737c91889bee4b83af30050bb134dcdcbc8ebf1705d8139b93192cfc9b4f802"
    end
    on_intel do
      url "https://github.com/takumi3488/hc/releases/download/v0.1.2/hc-x86_64-linux-musl.tar.gz"
      sha256 "4b2aab560d9e26f6bad5dc17f849fb970012531b7c578c801229997b54453dc6"
    end
  end

  def install
    bin.install "hc"
  end

  test do
    ENV["HERDR_ENV"] = "0"
    assert_equal "hc-homebrew-smoke
", shell_output("#{bin}/hc -- /bin/echo hc-homebrew-smoke")
    assert_empty shell_output("#{bin}/hc -- /bin/sh -c 'exit 37'", 37)
  end
end
