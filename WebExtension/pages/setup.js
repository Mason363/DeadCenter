const api = globalThis.browser ?? globalThis.chrome;

const word = {
  before: document.querySelector(".before"),
  pivot: document.querySelector(".pivot"),
  after: document.querySelector(".after"),
};

// Same pivot rule as the app: about a third of the way into the word.
function show(text) {
  const letters = [...text.replace(/[.,!?;:]+$/, "")];
  const pivot = letters.length <= 1 ? 0 : letters.length <= 5 ? 1 : letters.length <= 9 ? 2 : letters.length <= 13 ? 3 : 4;
  const all = [...text];
  word.before.textContent = all.slice(0, pivot).join("");
  word.pivot.textContent = all[pivot] ?? "";
  word.after.textContent = all.slice(pivot + 1).join("");
}

let loop;

function play(words) {
  clearTimeout(loop);
  if (matchMedia("(prefers-reduced-motion: reduce)").matches) return show(words.at(-1));
  let index = 0;
  const step = () => {
    show(words[index]);
    const last = index === words.length - 1;
    index = (index + 1) % words.length;
    loop = setTimeout(step, last ? 1800 : 260);
  };
  step();
}

const detail = decodeURIComponent(location.hash.slice(1));
if (detail) document.getElementById("detail").textContent = detail;
play(["Open", "Dead", "Center", "once."]);

const retry = document.getElementById("retry");
retry.addEventListener("click", async () => {
  retry.disabled = true;
  retry.textContent = "Connecting…";
  let reply;
  try {
    reply = await api.runtime.sendMessage({ type: "hello" });
  } catch (error) {
    reply = { ok: false, error: String(error?.message ?? error) };
  }
  if (reply?.ok) {
    document.getElementById("waiting").hidden = true;
    document.getElementById("connected").hidden = false;
    play(["Ready."]);
    return;
  }
  document.getElementById("detail").textContent = reply?.error ?? "";
  retry.disabled = false;
  retry.textContent = "Try Again";
});
