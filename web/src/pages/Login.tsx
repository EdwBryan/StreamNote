import { useEffect, useState, type FormEvent } from 'react';
import { api, setToken, type User } from '../api';
import { useSession } from '../App';
import { cognito, finishLogin, startLogin } from '../cognito';

/** En AWS se entra con Cognito; en local, con el inicio de sesión de desarrollo. */
export function Login() {
  return (
    <div className="login">
      <div className="login-page">
        <h1>StreamNote</h1>
        <p className="lede">Toma apuntes por módulos, compártelos en clase y repasa las grabaciones de tu comunidad.</p>
        {cognito ? <CognitoLogin /> : <DevLogin />}
      </div>
    </div>
  );
}

function CognitoLogin() {
  const { signIn } = useSession();
  const [error, setError] = useState<string | null>(null);
  // Al volver de Cognito la dirección trae ?code=…: se muestra «Entrando…» mientras se canjea
  const [busy, setBusy] = useState(() => window.location.search.includes('code='));

  useEffect(() => {
    let alive = true;
    finishLogin()
      .then(async (idToken) => {
        if (!idToken) return;
        setToken(idToken);
        const user = await api<User>('GET', '/me');
        if (alive) signIn(idToken, user);
      })
      .catch((err) => {
        setToken(null);
        if (alive) setError((err as Error).message);
      })
      .finally(() => {
        if (alive) setBusy(false);
      });
    return () => {
      alive = false;
    };
  }, []);

  const go = (kind: 'login' | 'signup') => {
    setBusy(true);
    setError(null);
    startLogin(kind).catch((err) => {
      setError((err as Error).message);
      setBusy(false);
    });
  };

  return (
    <div className="stack">
      {error && <p className="error">{error}</p>}
      <button type="button" className="primary" disabled={busy} onClick={() => go('login')}>
        {busy ? 'Entrando…' : 'Entrar'}
      </button>
      <button type="button" disabled={busy} onClick={() => go('signup')}>
        Crear una cuenta
      </button>
      <p className="muted small">
        Entras con tu correo y una contraseña en la página segura de Amazon Cognito. La primera vez te llega un código al correo para
        confirmarlo.
      </p>
    </div>
  );
}

function DevLogin() {
  const { signIn } = useSession();
  const [email, setEmail] = useState('');
  const [name, setName] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const r = await api<{ token: string; user: User }>('POST', '/auth/dev-login', { email, name });
      signIn(r.token, r.user);
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <form onSubmit={submit} className="stack">
        <label>
          Correo
          <input type="email" required autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="tu@upao.edu.pe" />
        </label>
        <label>
          Nombre
          <input required maxLength={60} value={name} onChange={(e) => setName(e.target.value)} placeholder="Cómo te verán los demás" />
        </label>
        {error && <p className="error">{error}</p>}
        <button className="primary" disabled={busy}>
          {busy ? 'Entrando…' : 'Entrar'}
        </button>
      </form>
      <p className="muted small">Inicio de sesión de desarrollo: no pide contraseña. En AWS lo reemplaza Amazon Cognito.</p>
    </>
  );
}
