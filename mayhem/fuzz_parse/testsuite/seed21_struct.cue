#Schema: {
	name:    string
	age?:    int & >=0
	emails: [...string]
}

data: #Schema & {
	name:   "alice"
	age:    30
	emails: ["a@example.com"]
}
