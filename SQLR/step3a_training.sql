SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- Stored Procedure to train a Logistic Regression. 
-- @dataset_name: specify the name of the featurized data set. 

DROP PROCEDURE IF EXISTS [dbo].[train_model];
GO

CREATE PROCEDURE [train_model]  @dataset_name varchar(max) 
AS 
BEGIN

	-- Create an empty table to be filled with the trained models.
    DROP TABLE if exists  [dbo].[Model]
	CREATE TABLE [dbo].[Model](
		[id] [varchar](200) NOT NULL, 
	    [value] [varbinary](max), 
			CONSTRAINT unique_id3 UNIQUE(id)
		) 
		

	-- Get the database name.
	DECLARE @database_name varchar(max) = db_name();

	-- Train the model on the training set.	
	EXECUTE sp_execute_external_script @language = N'R',
									   @script = N' 

##########################################################################################################################################
##	Connection String
##########################################################################################################################################
# Define the connection string
connection_string <- paste("Driver=SQL Server;Server=localhost;Database=", database_name, ";Trusted_Connection=true;", sep="")

########################################################################################################################################## 
## Get the column information.
########################################################################################################################################## 
# Create an Odbc connection with SQL Server using the name of the table storing the bins. 
OdbcModel <- RxOdbcData(table = "Column_Info", connectionString = connection_string) 

# Read the model from SQL.  
column_info <- rxReadObject(OdbcModel, "Column Info") 

# Set the Compute Context to SQL for faster training.
sql <- RxInSqlServer(connectionString = connection_string)
rxSetComputeContext(sql)

##########################################################################################################################################
##	Point to the training set and use the column_info list to specify the types of the features.
##########################################################################################################################################
Train_sql <- RxSqlServerData(sqlQuery = sprintf( "SELECT [%s].* FROM [%s] JOIN Hash_Id ON [%s].loanId = Hash_Id.loanId WHERE hashCode <= 70", dataset_name, dataset_name, dataset_name),
                             connectionString = connection_string,  
						     colInfo = column_info) 

##########################################################################################################################################
##	Specify the variables to keep for the training 
##########################################################################################################################################
# We remove the id variables, date, residentialState, term, and all the numeric variables that were later bucketed. 
  variables_all <- rxGetVarNames(Train_sql)
  variables_to_remove <- c("loanId", "memberId", "loanStatus", "date", "residentialState", "term",
                           "loanAmount", "interestRate", "monthlyPayment", "annualIncome", "dtiRatio", "lengthCreditHistory",
                           "numTotalCreditLines", "numOpenCreditLines", "numOpenCreditLines1Year", "revolvingBalance",
                           "revolvingUtilizationRate", "numDerogatoryRec", "numDelinquency2Years", "numChargeoff1year", 
                           "numInquiries6Mon")
  
  training_variables <- variables_all[!(variables_all %in% c("isBad", variables_to_remove))]
  formula <- as.formula(paste("isBad ~", paste(training_variables, collapse = "+")))

##########################################################################################################################################
## Train the Logistic Regression Model and Save the model in SQL Server
##########################################################################################################################################
logistic_model <- rxLogit(formula = formula,
                          data = Train_sql,
                          reportProgress = 0, 
                          initialValues = NA)

## rxLogisticRegression function from the MicrosoftML library can be used instead. 
## The regularization weights (l1Weight and l2Weight) can be modified for further optimization.
## The included selectFeatures function can select a certain number of optimal features based on a specified method.
## the number of variables to select and the method can be further optimized.
  
#library("MicrosoftML")
#logistic_model <- rxLogisticRegression(formula = formula,
#                                       data = Train_sql,
#                                       type = "binary",
#                                       l1Weight = 0.7,
#                                       l2Weight = 0.7,
#                                       mlTransforms = list(selectFeatures(formula, mode = mutualInformation(numFeaturesToKeep = 10))))
   
########################################################################################################################################## 
## Save the model in SQL Server 
########################################################################################################################################## 
# Set the compute context to local for tables exportation to SQL.  
rxSetComputeContext("local") 

# Open an Odbc connection with SQL Server. 
OdbcModel <- RxOdbcData(table = "Model", connectionString = connection_string) 
rxOpen(OdbcModel, "w") 

# Write the model to SQL.  
rxWriteObject(OdbcModel, "Logistic Regression", logistic_model) 

##########################################################################################################################################
## Write the coefficients of the variables to a SQL table in decreasing order of absolute value of coefficients. 
##########################################################################################################################################
# Get the table. 
coeff <- logistic_model$coefficients
Logistic_Coeff <- data.frame(variable = names(coeff), coefficient = coeff, row.names = NULL)
Logistic_Coeff <- Logistic_Coeff[order(abs(Logistic_Coeff$coefficient), decreasing = T),]

# Export it to SQL. 
Logistic_Coeff_sql <- RxSqlServerData(table = "Logistic_Coeff", connectionString = connection_string)
rxDataStep(inData = Logistic_Coeff, outFile = Logistic_Coeff_sql, overwrite = TRUE)
'

, @params = N' @dataset_name varchar(max), @database_name varchar(max)'
, @dataset_name =  @dataset_name
, @database_name = @database_name

;
END
GO

