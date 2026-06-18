import ProtectedRoute from './auth/ProtectedRoute'
import { useAuth } from './auth/AuthProvider'

function Dashboard() {
  const { user, logout } = useAuth()

  return (
    <div style={styles.container}>
      <header style={styles.header}>
        <h2 style={styles.logo}>Aham Store</h2>
        <div style={styles.userBar}>
          <img src={user.picture} alt={user.name} style={styles.avatar} />
          <span style={styles.userName}>{user.name}</span>
          <button onClick={logout} style={styles.logoutBtn}>Sign out</button>
        </div>
      </header>
      <main style={styles.main}>
        {/* Document upload and query UI — implemented in Phase 6 */}
        <p style={{ color: '#888' }}>Your library will appear here.</p>
      </main>
    </div>
  )
}

export default function App() {
  return (
    <ProtectedRoute>
      <Dashboard />
    </ProtectedRoute>
  )
}

const styles = {
  container: { minHeight: '100vh', display: 'flex', flexDirection: 'column' },
  header: {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'space-between',
    padding: '0.75rem 1.5rem',
    borderBottom: '1px solid #e0e0e0',
    background: '#fff',
  },
  logo: { margin: 0, fontSize: '1.25rem' },
  userBar: { display: 'flex', alignItems: 'center', gap: '0.75rem' },
  avatar: { width: 32, height: 32, borderRadius: '50%' },
  userName: { fontSize: '0.9rem' },
  logoutBtn: {
    background: 'none',
    border: '1px solid #ccc',
    borderRadius: '6px',
    padding: '0.3rem 0.75rem',
    cursor: 'pointer',
    fontSize: '0.85rem',
  },
  main: { flex: 1, padding: '2rem' },
}
