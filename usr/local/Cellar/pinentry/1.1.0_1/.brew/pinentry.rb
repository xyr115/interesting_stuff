class Pinentry < Formula
  desc "Passphrase entry dialog utilizing the Assuan protocol"
  homepage "https://www.gnupg.org/related_software/pinentry/"
  url "https://www.gnupg.org/ftp/gcrypt/pinentry/pinentry-1.1.0.tar.bz2"
  mirror "https://www.mirrorservice.org/sites/ftp.gnupg.org/gcrypt/pinentry/pinentry-1.1.0.tar.bz2"
  sha256 "68076686fa724a290ea49cdf0d1c0c1500907d1b759a3bcbfbec0293e8f56570"
  revision 1

  depends_on "pkg-config" => :build
  depends_on "libgpg-error"
  depends_on "libassuan"
  depends_on "gtk+" => :optional

  def install
    args = %W[
      --disable-dependency-tracking
      --disable-silent-rules
      --prefix=#{prefix}
      --disable-pinentry-qt
      --disable-pinentry-qt5
      --disable-pinentry-gnome3
      --disable-pinentry-tqt
      --disable-pinentry-fltk
      --enable-pinentry-tty
    ]

    args << "--disable-pinentry-gtk2" if build.without? "gtk+"

    system "./configure", *args
    system "make", "install"
  end

  test do
    system "#{bin}/pinentry", "--version"
    system "#{bin}/pinentry-tty", "--version"
  end
end
