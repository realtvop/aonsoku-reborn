import { LazyLoadImage } from "react-lazy-load-image-component";

import { LoginForm } from "@/app/components/login/form";
import appIcon from "@/assets/icon_transparent.svg";

export default function Login() {
  return (
    <div className="flex w-screen h-screen bg-background-foreground">
      {/* Left side - brand */}
      <div className="hidden lg:flex lg:w-1/2 flex-col justify-center items-center bg-muted/30">
        <div className="flex flex-col items-center text-center space-y-6">
          <LazyLoadImage
            src={appIcon}
            alt="Aonsoku"
            className="w-20 h-20"
          />
          <h1 className="text-4xl font-bold tracking-tight text-foreground">
            Aonsoku
          </h1>
        </div>
      </div>

      {/* Right side - form */}
      <div className="flex-1 flex flex-col justify-center items-center p-6">
        {/* Mobile logo */}
        <div className="lg:hidden flex flex-col items-center mb-8 space-y-3">
          <LazyLoadImage
            src={appIcon}
            alt="Aonsoku"
            className="w-12 h-12"
          />
          <h1 className="text-xl font-semibold text-foreground">Aonsoku</h1>
        </div>

        <div className="w-full max-w-[420px]">
          <LoginForm />
        </div>
      </div>
    </div>
  );
}
