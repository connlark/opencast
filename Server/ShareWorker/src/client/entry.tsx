import { hydrateRoot } from "react-dom/client";
import { Player, type PlayerProps } from "../app/Player.tsx";
import "../app/styles.css";

// Only the player hydrates; the document shell around <main id="app"> is static.
const root = document.getElementById("app");
const state = document.getElementById("__share")?.textContent;
if (root && state) {
  hydrateRoot(root, <Player {...(JSON.parse(state) as PlayerProps)} />);
}
