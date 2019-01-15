class Adns < Formula
  desc "C/C++ resolver library and DNS resolver utilities"
  homepage "https://www.chiark.greenend.org.uk/~ian/adns/"
  url "https://www.chiark.greenend.org.uk/~ian/adns/ftp/adns-1.5.1.tar.gz"
  sha256 "5b1026f18b8274be869245ed63427bf8ddac0739c67be12c4a769ac948824eeb"
  head "git://git.chiark.greenend.org.uk/~ianmdlvl/adns.git"

  def install
    system "./configure", "--prefix=#{prefix}", "--disable-dynamic"
    system "make"
    system "make", "install"
  end

  test do
    system "#{bin}/adnsheloex", "--version"
  end
end
