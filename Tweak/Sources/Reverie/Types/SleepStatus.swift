enum SleepStatus {
    case autoSlept // Unplugged, locked, idle
    case autoWoken // Charger attached
    case dreamless // In a state unrelated to Reverie
    case userSlept // CC module or prefs button pressed
    case userWoken // Volume down pressed five times
}
